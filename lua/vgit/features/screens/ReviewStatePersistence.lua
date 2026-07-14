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
      branch count as one)
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

-- List branches (one per directory) sorted by lastUsed, oldest first. A branch's
-- lastUsed is the most recent across its review-type files (by_file/by_commit).
local function list_branches(state_dir)
  if not fs.exists(state_dir) then return {} end

  -- Reduce each branch dir's state files to its most recent lastUsed.
  local last_used = {}
  for _, filepath in ipairs(vim.fn.glob(state_dir .. '/**/*.json', false, true)) do
    local content = fs.read_file(filepath)
    if content then
      local ok, data = pcall(vim.fn.json_decode, table.concat(content, '\n'))
      if ok and data and data.lastUsed then
        local dir = fs.dirname(filepath)
        last_used[dir] = math.max(last_used[dir] or 0, data.lastUsed)
      end
    end
  end

  local branches = {}
  for dir, lastUsed in pairs(last_used) do
    branches[#branches + 1] = { dir = dir, lastUsed = lastUsed }
  end
  table.sort(branches, function(a, b) return a.lastUsed < b.lastUsed end)
  return branches
end

-- Evict least-recently-used branches until adding one more stays within capacity
local function evict_if_needed(state_dir)
  local branches = list_branches(state_dir)
  while #branches >= MAX_BRANCHES do
    local oldest = table.remove(branches, 1)
    vim.fn.delete(oldest.dir, 'rf') -- Remove the branch dir and all its state files
  end
end

-- Load state from disk
-- Returns: state_data or nil, error_message or nil
function ReviewStatePersistence.load(repo_name, branch_name, review_type)
  local path = ReviewStatePersistence.get_state_path(repo_name, branch_name, review_type)

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

-- Save state to disk
function ReviewStatePersistence.save(repo_name, branch_name, review_type, state_data)
  local path = ReviewStatePersistence.get_state_path(repo_name, branch_name, review_type)
  local state_dir = ReviewStatePersistence.get_state_dir(repo_name)
  local branch_dir = fs.dirname(path)

  -- Evict LRU branches before adding a new one. Adding another review type to an
  -- existing branch doesn't count, so only evict when the branch dir is new.
  if not fs.exists(branch_dir) then
    evict_if_needed(state_dir)
  end

  -- Ensure full directory path exists (branch subdirs)
  ensure_dir(branch_dir)

  -- Add metadata
  state_data.version = CURRENT_VERSION
  state_data.lastUsed = os.time()
  state_data.branchName = branch_name

  local json = vim.fn.json_encode(state_data)
  local lines = { json }
  fs.write_file(path, lines)
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
