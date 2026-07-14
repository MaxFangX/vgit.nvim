local loop = require('vgit.core.loop')
local Object = require('vgit.core.Object')
local console = require('vgit.core.console')
local persistence = require('vgit.features.screens.IndexedReviewPersistence')

--[[
  IndexedReviewState manages the "index" for indexed review workflows: an
  approved content snapshot per mark_key (the git-index analogy — approved is
  to base/current what the index is to HEAD/worktree).

  State is keyed by (base_branch, branch_name, review_type) where review_type
  is 'by_file_indexed' or 'by_commit_indexed'.

  An approved record is { lines = {...}, deleted = bool }. No record means
  approved == base (nothing seen). Records persist to disk as content-
  addressed objects referenced from the review-type JSON file.
]]

local IndexedReviewState = Object:extend()

-- Global state storage (persists across screen instances within a Vim session)
local state_store = {}

function IndexedReviewState:constructor(opts)
  opts = opts or {}

  return {
    base_branch = opts.base_branch,
    branch_name = opts.branch_name,
    review_type = opts.review_type or 'by_file_indexed',
    repo_name = opts.repo_name,
    _loaded = false,           -- Whether state has been loaded from disk
    _skip_persistence = false, -- Set if user declines to delete corrupted state
  }
end

function IndexedReviewState:get_state_key()
  return string.format('%s|%s|%s', self.base_branch or '', self.branch_name or '', self.review_type)
end

local function get_state(self)
  local key = self:get_state_key()
  if not state_store[key] then
    state_store[key] = { approved = {}, position = { section = 'unseen' } }
  end
  return state_store[key]
end

-- Load state from disk (call explicitly from coroutine context)
function IndexedReviewState:load_from_disk()
  if not self.repo_name or self._loaded then return end
  self._loaded = true

  -- Escape luv callback context to main Vim loop (required for vim.fn calls)
  loop.free_textlock()
  local data, err = persistence.load(self.repo_name, self.branch_name, self.review_type)

  if err then
    local path = persistence.get_state_path(self.repo_name, self.branch_name, self.review_type)
    local should_delete = persistence.handle_load_error(path, err)
    if should_delete then
      persistence.delete(self.repo_name, self.branch_name, self.review_type)
    else
      self._skip_persistence = true -- Don't overwrite
    end
    return
  end

  if not data or type(data.entries) ~= 'table' then return end

  -- Materialize approved snapshots from the object store. A missing object
  -- means the snapshot was lost; drop the entry (file reverts to unseen).
  local approved, missing = {}, 0
  for mark_key, entry in pairs(data.entries) do
    if type(entry) == 'table' and entry.approved then
      local lines = persistence.read_object(self.repo_name, self.branch_name, entry.approved)
      if lines then
        approved[mark_key] = { lines = lines, deleted = entry.deleted == true }
      else
        missing = missing + 1
      end
    end
  end
  if missing > 0 then
    console.warn(string.format('Review state: %d approved snapshot(s) missing, files reset to unseen', missing))
  end

  local key = self:get_state_key()
  local existing = state_store[key]
  state_store[key] = {
    approved = approved,
    position = existing and existing.position or { section = 'unseen' },
  }
end

-- Get the approved snapshot for a mark_key: { lines, deleted } or nil
-- (nil means approved == base, i.e. nothing seen)
function IndexedReviewState:get_approved(mark_key)
  return get_state(self).approved[mark_key]
end

function IndexedReviewState:set_approved(mark_key, lines, deleted)
  get_state(self).approved[mark_key] = { lines = lines, deleted = deleted == true }
end

function IndexedReviewState:remove_approved(mark_key)
  get_state(self).approved[mark_key] = nil
end

-- Reset the index for the current session (everything back to unseen)
function IndexedReviewState:reset()
  get_state(self).approved = {}
end

-- Store last viewed file for re-entry fallback (when current buffer is not in review)
-- commit_message: first line of commit message (stable across rebases, unlike hash)
-- focus: 'diff' or 'list' - which component had focus
function IndexedReviewState:save_position(section, filepath, commit_message, focus)
  get_state(self).position = {
    section = section,
    filepath = filepath,
    commit_message = commit_message,
    focus = focus,
  }
end

-- Get last viewed file for re-entry fallback
-- Returns: section, filepath, commit_message, focus
function IndexedReviewState:get_position()
  local pos = get_state(self).position
  return pos.section or 'unseen', pos.filepath, pos.commit_message, pos.focus
end

-- Save state to disk: write snapshot objects, then the JSON referencing them,
-- then sweep unreferenced objects. Position is session-only, never persisted.
function IndexedReviewState:save()
  if not self.repo_name or self._skip_persistence then return end

  -- Escape luv callback context to main Vim loop (required for vim.fn calls)
  loop.free_textlock()
  local state = get_state(self)

  local entries, objects = {}, {}
  for mark_key, record in pairs(state.approved) do
    local hash = persistence.hash_lines(record.lines)
    entries[mark_key] = { approved = hash, deleted = record.deleted or nil }
    objects[hash] = record.lines
  end

  persistence.write_objects(self.repo_name, self.branch_name, objects)
  persistence.save(self.repo_name, self.branch_name, self.review_type, { entries = entries })
  persistence.sweep_objects(self.repo_name, self.branch_name)
end

return IndexedReviewState
