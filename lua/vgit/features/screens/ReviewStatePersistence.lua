local fs = require('vgit.core.fs')
local console = require('vgit.core.console')
local loop = require('vgit.core.loop')

--[[
  ReviewStatePersistence handles disk I/O for review state.

  Storage location: $XDG_DATA_HOME/vgit/<repo>/<branch>/<type>.json
  (default: ~/.local/share/vgit/<repo>/<branch>/<type>.json)

  Branch names with / are encoded as -- (e.g., feature/foo -> feature--foo)

  Features:
    - LRU eviction: max 128 branches per repository (all review types for a
      branch count as one), run from the quit-time save via evict_lru
    - Schema versioning: graceful migration with user prompts
    - Automatic lastUsed timestamp updates
]]

local ReviewStatePersistence = {}

local CURRENT_VERSION = 1
local MAX_BRANCHES = 128

-- Get XDG data home directory. Prefers env vars (safe in fast event contexts)
-- over vim.fn.expand, since `branch_by_subjects` below may run from the branch resolver.
local function get_data_home()
  local xdg = os.getenv('XDG_DATA_HOME')
  if xdg and xdg ~= '' then
    return xdg
  end
  local home = os.getenv('HOME')
  if home and home ~= '' then
    return home .. '/.local/share'
  end
  return vim.fn.expand('~/.local/share')
end

-- Encode branch name for filesystem (/ -> --)
local function encode_branch(name)
  return name:gsub('/', '--')
end

-- Get state directory path for a repo
function ReviewStatePersistence.get_state_dir(repo_name)
  return get_data_home() .. '/vgit/' .. repo_name
end

-- Get state file path for a (repo, branch, review_type) tuple
function ReviewStatePersistence.get_state_path(repo_name, branch_name, review_type)
  local dir = ReviewStatePersistence.get_state_dir(repo_name)
  return dir .. '/' .. encode_branch(branch_name) .. '/' .. review_type .. '.json'
end

-- Minimum shared commit-subjects for a stored review to be considered "the review
-- for HEAD" — guards against a coincidental one-commit overlap between branches.
local MIN_SUBJECT_OVERLAP = 2

-- Read a by_commit review file and count how many of its marked hunks' commit
-- subjects (the `subject_hash` prefix of each mark key) appear in `head_subjects`.
-- Exported for IndexedReviewPersistence, which folds it into its own resolver.
function ReviewStatePersistence.subject_overlap(path, head_subjects)
  local fd = io.open(path, 'r')
  if not fd then return 0, nil, 0 end
  local content = fd:read('*a')
  fd:close()

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= 'table' or type(data.marks) ~= 'table' or not data.branchName then
    return 0, nil, 0, 0
  end

  -- Also count the review's distinct stored subjects, so the caller can scale
  -- its overlap threshold to reviews smaller than the absolute minimum.
  local overlap, stored, counted = 0, 0, {}
  for key, seen in pairs(data.marks) do
    if seen == true then
      local subject = key:match('^([^:]+)')
      if subject and not counted[subject] then
        counted[subject] = true
        stored = stored + 1
        if head_subjects[subject] then overlap = overlap + 1 end
      end
    end
  end
  return overlap, data.branchName, data.lastUsed or 0, stored
end

-- Resolve which stored review (branch) best covers HEAD's current commits, keyed on
-- commit subjects (rebase-stable, like the marks) so a review is followed across
-- rebases regardless of where the branch bookmark sits. A review qualifies with
-- `MIN_SUBJECT_OVERLAP` matching subjects; below that (a single-commit stack can
-- otherwise never match) it qualifies only if *all* its stored subjects match AND
-- they cover at least half of HEAD's stack — one stray subject (e.g. marks saved
-- under a misresolved key) must not claim a larger stack away from its bookmark.
-- Returns the qualifying branch with the most overlap (ties break toward the most
-- recently used), or nil. Uses libuv/io/vim.json so it's safe in the fast event
-- contexts where the branch resolver runs.
function ReviewStatePersistence.branch_by_subjects(repo_name, head_subjects)
  local head_count = 0
  for _ in pairs(head_subjects) do
    head_count = head_count + 1
  end
  if head_count == 0 then return nil end

  local state_dir = ReviewStatePersistence.get_state_dir(repo_name)
  local handle = vim.loop.fs_scandir(state_dir)
  if not handle then return nil end

  local best_name, best_overlap, best_used = nil, 0, 0
  while true do
    local entry, entry_type = vim.loop.fs_scandir_next(handle)
    if not entry then break end
    if entry_type == 'directory' then
      local path = state_dir .. '/' .. entry .. '/by_commit.json'
      local overlap, branch_name, last_used, stored = ReviewStatePersistence.subject_overlap(path, head_subjects)
      local qualifies = overlap >= MIN_SUBJECT_OVERLAP
        or (overlap > 0 and overlap == stored and 2 * overlap >= head_count)
      if qualifies and (overlap > best_overlap or (overlap == best_overlap and last_used > best_used)) then
        best_name, best_overlap, best_used = branch_name, overlap, last_used
      end
    end
  end

  return best_name
end

-- Ensure state directory exists
local function ensure_dir(dir)
  if not fs.exists(dir) then
    vim.fn.mkdir(dir, 'p')
  end
end

-- Mtime (seconds) of the newest state file directly in `dir`, or nil if it
-- holds none. Stat only; save() writes lastUsed and the file at the same
-- instant, so mtime orders branches identically without parsing JSON.
local function newest_state_mtime(dir)
  local handle = vim.loop.fs_scandir(dir)
  if not handle then return nil end

  local newest
  while true do
    local entry, entry_type = vim.loop.fs_scandir_next(handle)
    if not entry then break end
    if entry_type == 'file' and entry:match('%.json$') then
      local stat = vim.loop.fs_stat(dir .. '/' .. entry)
      if stat and (not newest or stat.mtime.sec > newest) then newest = stat.mtime.sec end
    end
  end
  return newest
end

-- List branch dirs holding state, sorted by last use, oldest first. Branch
-- dirs with no state files left are pruned on the way (rmdir only succeeds
-- when empty, so an objects/ dir or stray file keeps the dir).
local function list_branches(state_dir)
  local handle = vim.loop.fs_scandir(state_dir)
  if not handle then return {} end

  local branches = {}
  while true do
    local entry, entry_type = vim.loop.fs_scandir_next(handle)
    if not entry then break end
    if entry_type == 'directory' then
      local dir = state_dir .. '/' .. entry
      local last_used = newest_state_mtime(dir)
      if last_used then
        branches[#branches + 1] = { dir = dir, last_used = last_used }
      else
        vim.loop.fs_rmdir(dir)
      end
    end
  end

  table.sort(branches, function(a, b) return a.last_used < b.last_used end)
  return branches
end

-- Evict least-recently-used branches until the repo is within capacity.
-- Called from the quit-time save (never the write-behind one): the current
-- branch was just saved, so it sorts newest and is never a candidate.
function ReviewStatePersistence.evict_lru(repo_name)
  local branches = list_branches(ReviewStatePersistence.get_state_dir(repo_name))
  for i = 1, #branches - MAX_BRANCHES do
    vim.fn.delete(branches[i].dir, 'rf') -- Remove the branch dir and all its state files
  end
end

-- Load a state file by path. Returns: state_data or nil, error_message or nil
local function load_path(path)
  if not fs.exists(path) then
    return nil, nil -- No existing state (not an error)
  end

  local content = fs.read_file(path)
  if not content then
    return nil, 'Failed to read file'
  end

  local ok, data = pcall(vim.fn.json_decode, table.concat(content, '\n'))
  if not ok or not data then
    return nil, 'Failed to parse JSON'
  end

  if data.version ~= CURRENT_VERSION then
    return nil, string.format('Schema version mismatch (got %s, expected %s)', data.version, CURRENT_VERSION)
  end

  return data, nil
end

-- Load state from disk
-- Returns: state_data or nil, error_message or nil
function ReviewStatePersistence.load(repo_name, branch_name, review_type)
  return load_path(ReviewStatePersistence.get_state_path(repo_name, branch_name, review_type))
end

-- Decoded sibling state files by path, each tagged with the file's mtime, so
-- opening a review re-reads only the sibling files that changed since.
local sibling_cache = {}

-- The other branches' readable state files for `review_type`, most recently
-- used first, as `{ branch_name, data }` tables.
function ReviewStatePersistence.load_siblings(repo_name, branch_name, review_type)
  local state_dir = ReviewStatePersistence.get_state_dir(repo_name)
  local handle = vim.loop.fs_scandir(state_dir)
  if not handle then return {} end

  local own_dir = encode_branch(branch_name)
  local siblings = {}
  while true do
    local entry, entry_type = vim.loop.fs_scandir_next(handle)
    if not entry then break end
    local path = state_dir .. '/' .. entry .. '/' .. review_type .. '.json'
    local stat = entry_type == 'directory' and entry ~= own_dir and vim.loop.fs_stat(path)
    if stat then
      local mtime = string.format('%d.%d', stat.mtime.sec, stat.mtime.nsec)
      local cached = sibling_cache[path]
      if not cached or cached.mtime ~= mtime then
        cached = { mtime = mtime, data = load_path(path) }
        sibling_cache[path] = cached
      end
      if cached.data and cached.data.branchName then
        siblings[#siblings + 1] = { branch_name = cached.data.branchName, data = cached.data }
      end
    end
  end

  table.sort(siblings, function(a, b) return (a.data.lastUsed or 0) > (b.data.lastUsed or 0) end)
  return siblings
end

-- Save state to disk. Does not evict; see evict_lru.
function ReviewStatePersistence.save(repo_name, branch_name, review_type, state_data)
  local path = ReviewStatePersistence.get_state_path(repo_name, branch_name, review_type)
  ensure_dir(fs.dirname(path))

  -- Add metadata
  state_data.version = CURRENT_VERSION
  state_data.lastUsed = os.time()
  state_data.branchName = branch_name

  fs.write_file_atomic(path, { vim.fn.json_encode(state_data) })
end

-- Delete state file
function ReviewStatePersistence.delete(repo_name, branch_name, review_type)
  local path = ReviewStatePersistence.get_state_path(repo_name, branch_name, review_type)
  if fs.exists(path) then
    fs.remove_file(path)
  end
end

-- Handle load error with user prompt
-- Returns: true if user chose to delete, false otherwise
function ReviewStatePersistence.handle_load_error(path, error_msg)
  loop.free_textlock()
  console.warn(string.format('Failed to load review state: %s', error_msg))
  console.warn(string.format('State file: %s', path))

  local decision = console.input('Delete corrupted state and start fresh? (y/N) '):lower()
  return decision == 'y' or decision == 'yes'
end

return ReviewStatePersistence
