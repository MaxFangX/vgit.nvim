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

-- Get XDG data home directory
local function get_data_home()
  local xdg = os.getenv('XDG_DATA_HOME')
  if xdg and xdg ~= '' then
    return xdg
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
