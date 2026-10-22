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

  An approved record is { lines = {...}, deleted = bool, base_lines = {...} }
  where base_lines is the base the approval was made against (used to rebase
  the snapshot when the base changes; absent on legacy records). No record
  means approved == base (nothing seen). Records persist to disk as content-
  addressed objects referenced from the review-type JSON file.
]]

local IndexedReviewState = Object:extend()

-- Write-behind delay: a burst of marks coalesces into one save shortly after
-- it settles, so a crash or kill mid-review loses at most this much work.
local SAVE_DEBOUNCE_MS = 1000

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

-- Mtime of the on-disk state file, or nil if absent. Used to detect writes
-- by other sessions.
local function state_file_mtime(self)
  local path = persistence.get_state_path(self.repo_name, self.branch_name, self.review_type)
  local stat = vim.loop.fs_stat(path)
  return stat and string.format('%d.%d', stat.mtime.sec, stat.mtime.nsec) or nil
end

-- Load state from disk (call explicitly from coroutine context). Every save
-- goes through the in-session store, so it is the source of truth within a
-- session, and re-entering a review skips re-reading the object store,
-- unless the state file's mtime shows another session wrote it since we
-- last touched it.
function IndexedReviewState:load_from_disk()
  if not self.repo_name or self._loaded then return end
  self._loaded = true

  local state = get_state(self)
  local mtime = state_file_mtime(self)
  if state.loaded and state.disk_mtime == mtime then return end

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

  if not data or type(data.entries) ~= 'table' then
    state.loaded = true
    state.disk_mtime = mtime
    return
  end

  -- Materialize approved snapshots from the object store. A missing object
  -- means the snapshot was lost; drop the entry (file reverts to unseen).
  -- A missing base object only loses the ability to rebase the snapshot.
  local approved, missing = {}, 0
  for mark_key, entry in pairs(data.entries) do
    if type(entry) == 'table' and entry.approved then
      local lines = persistence.read_object(self.repo_name, self.branch_name, entry.approved)
      if lines then
        local base_lines = entry.base and persistence.read_object(self.repo_name, self.branch_name, entry.base)
        approved[mark_key] = {
          lines = lines,
          deleted = entry.deleted == true,
          base_lines = base_lines,
          -- Cache content hashes so save() doesn't re-hash unchanged records
          hash = entry.approved,
          base_hash = base_lines and entry.base or nil,
        }
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
    loaded = true,
    disk_mtime = mtime,
  }
end

-- Get the approved snapshot for a mark_key: { lines, deleted, base_lines }
-- or nil (nil means approved == base, i.e. nothing seen)
function IndexedReviewState:get_approved(mark_key)
  return get_state(self).approved[mark_key]
end

-- base_lines: the base content the approval was made against; lets the model
-- rebase the snapshot when the base later changes (stack restructuring).
-- Content hashes are computed lazily on save() and cached on the record.
function IndexedReviewState:set_approved(mark_key, lines, deleted, base_lines)
  get_state(self).approved[mark_key] = { lines = lines, deleted = deleted == true, base_lines = base_lines }
  self:schedule_save()
end

function IndexedReviewState:remove_approved(mark_key)
  get_state(self).approved[mark_key] = nil
  self:schedule_save()
end

-- Reset the index for the current session (everything back to unseen)
function IndexedReviewState:reset()
  get_state(self).approved = {}
  self:schedule_save()
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

-- Write snapshot objects, then the JSON referencing them, then (optionally)
-- sweep unreferenced objects. Objects are immutable and content-addressed, so
-- unreferenced ones are harmless until the final save sweeps them.
local function write_to_disk(self, sweep)
  if not self.repo_name or self._skip_persistence then return end

  -- Escape luv callback context to main Vim loop (required for vim.fn calls)
  loop.free_textlock()
  local state = get_state(self)

  -- Records are immutable once set (set_approved replaces them wholesale),
  -- so cached hashes stay valid; only records new this session get hashed.
  local entries, objects = {}, {}
  for mark_key, record in pairs(state.approved) do
    record.hash = record.hash or persistence.hash_lines(record.lines)
    if record.base_lines then
      record.base_hash = record.base_hash or persistence.hash_lines(record.base_lines)
      objects[record.base_hash] = record.base_lines
    end
    entries[mark_key] = { approved = record.hash, deleted = record.deleted or nil, base = record.base_hash }
    objects[record.hash] = record.lines
  end

  persistence.write_objects(self.repo_name, self.branch_name, objects)
  persistence.save(self.repo_name, self.branch_name, self.review_type, { entries = entries })
  if sweep then
    persistence.sweep_objects(self.repo_name, self.branch_name)
  end

  -- Our own write shouldn't trigger a reload on the next entry
  state.loaded = true
  state.disk_mtime = state_file_mtime(self)
end

-- Queue a write-behind save; mark mutators call this so approvals reach disk
-- without waiting for the screen to close.
function IndexedReviewState:schedule_save()
  if not self._debounced_save then
    self._debounced_save = loop.debounce_coroutine(function() write_to_disk(self, false) end, SAVE_DEBOUNCE_MS)
  end
  self._debounced_save()
end

-- Save state to disk now and sweep unreferenced objects, superseding any
-- queued write-behind save. Position is session-only, never persisted.
function IndexedReviewState:save()
  if self._debounced_save then
    loop.close_debounced(self._debounced_save)
    self._debounced_save = nil
  end
  write_to_disk(self, true)
end

return IndexedReviewState
