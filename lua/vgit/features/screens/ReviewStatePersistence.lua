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
-- over vim.fn.expand, since IndexedReviewPersistence.branch_by_subjects may
-- run from the branch resolver.
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
