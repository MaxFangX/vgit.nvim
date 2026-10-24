local loop = require('vgit.core.loop')
local Object = require('vgit.core.Object')
local console = require('vgit.core.console')
local persistence = require('vgit.features.screens.ReviewPersistence')
local change_id_rekey = require('vgit.features.screens.change_id_rekey')

--[[
  ReviewState manages the "index" for review workflows: an approved
  content snapshot per mark_key (the git-index analogy — approved is
  to base/current what the index is to HEAD/worktree).

  State is keyed by (repo_name, branch_name, review_type), the identity of its
  state file, where review_type is 'by_file' or 'by_commit'.

  An approved record is { lines = {...}, deleted = bool, base_lines = {...} }
  where base_lines is the base the approval was made against (used to rebase
  the snapshot when the base changes; absent on legacy records). No record
  means approved == base (nothing seen). Records persist to disk as content-
  addressed objects referenced from the review-type JSON file, each with the
  jj change id of its commit when known (see change_id_rekey).

  A key whose record was removed (unmarked, reset, or rebased away) keeps a
  tombstone, persisted with its change id, so the record isn't adopted
  from another branch's review again.
]]

local ReviewState = Object:extend()

-- Write-behind delay: the first change after a save starts the timer and
-- later changes ride along, so a crash or kill mid-review loses at most this
-- much work, even while marks keep coming.
local SAVE_DELAY_MS = 1000

-- Global state storage (persists across screen instances within a Vim session)
local state_store = {}

function ReviewState:constructor(opts)
  opts = opts or {}

  return {
    base_branch = opts.base_branch,
    branch_name = opts.branch_name,
    review_type = opts.review_type or 'by_file',
    repo_name = opts.repo_name,
    _loaded = false,           -- Whether state has been loaded from disk
    _skip_persistence = false, -- Set when the state file must not be overwritten
  }
end

function ReviewState:get_state_key()
  return string.format('%s|%s|%s', self.repo_name or '', self.branch_name or '', self.review_type)
end

local function get_state(self)
  local key = self:get_state_key()
  if not state_store[key] then
    state_store[key] = { approved = {}, change_ids = {}, removed = {}, position = { section = 'unseen' } }
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

-- An entry's approved record, materialized from `branch_name`'s object store,
-- or nil if its snapshot object is missing. A missing base object only loses
-- the ability to rebase the snapshot.
local function read_record(repo_name, branch_name, entry)
  local lines = persistence.read_object(repo_name, branch_name, entry.approved)
  if not lines then return nil end

  local base_lines = entry.base and persistence.read_object(repo_name, branch_name, entry.base)
  return {
    lines = lines,
    deleted = entry.deleted == true,
    base_lines = base_lines,
    -- Cache content hashes so save() doesn't re-hash unchanged records
    hash = entry.approved,
    base_hash = base_lines and entry.base or nil,
  }
end

-- Load state from disk (call explicitly from coroutine context). Every save
-- goes through the in-session store, so it is the source of truth within a
-- session, and re-entering a review skips re-reading the object store,
-- unless the state file's mtime shows another session wrote it since we
-- last touched it.
function ReviewState:load_from_disk()
  if not self.repo_name or self._loaded then return end
  self._loaded = true

  local state = get_state(self)
  local mtime = state_file_mtime(self)
  if state.loaded and state.disk_mtime == mtime then return end

  -- Escape luv callback context to main Vim loop (required for vim.fn calls)
  loop.free_textlock()
  local data, err = persistence.load(self.repo_name, self.branch_name, self.review_type)

  -- Never prompt or delete: other sessions, possibly on other vgit
  -- versions, share the file. Leave a newer or unreadable file alone; a
  -- corrupt one is replaced by the next save.
  if err and (err.newer or err.unreadable) then
    console.warn(string.format('%s; review progress will not be saved this session', err[1]))
    self._skip_persistence = true
    return
  end
  if err then console.warn(string.format('Ignoring review state: %s', err[1])) end

  -- No file (never saved, or deleted since): nothing is approved
  if not data or type(data.entries) ~= 'table' then
    state.approved, state.change_ids, state.removed = {}, {}, {}
    state.loaded = true
    state.disk_mtime = mtime
    return
  end

  -- Materialize approved snapshots from the object store. A missing object
  -- means the snapshot was lost; drop the entry (file reverts to unseen).
  local approved, change_ids, removed, missing = {}, {}, {}, 0
  for mark_key, entry in pairs(data.entries) do
    if type(entry) == 'table' and entry.approved then
      local record = read_record(self.repo_name, self.branch_name, entry)
      if record then
        approved[mark_key], change_ids[mark_key] = record, entry.change_id
      else
        missing = missing + 1
      end
    elseif type(entry) == 'table' and entry.change_id then
      removed[mark_key], change_ids[mark_key] = true, entry.change_id
    end
  end
  if missing > 0 then
    console.warn(string.format('Review state: %d approved snapshot(s) missing, files reset to unseen', missing))
  end

  local key = self:get_state_key()
  local existing = state_store[key]
  state_store[key] = {
    approved = approved,
    change_ids = change_ids,
    removed = removed,
    position = existing and existing.position or { section = 'unseen' },
    loaded = true,
    disk_mtime = mtime,
  }
end

-- Get the approved snapshot for a mark_key: { lines, deleted, base_lines }
-- or nil (nil means approved == base, i.e. nothing seen)
function ReviewState:get_approved(mark_key)
  return get_state(self).approved[mark_key]
end

-- base_lines: the base content the approval was made against; lets the model
-- rebase the snapshot when the base later changes (stack restructuring).
-- Content hashes are computed lazily on save() and cached on the record.
function ReviewState:set_approved(mark_key, lines, deleted, base_lines)
  local state = get_state(self)
  state.approved[mark_key] = { lines = lines, deleted = deleted == true, base_lines = base_lines }
  state.removed[mark_key] = nil
  self:schedule_save()
end

function ReviewState:remove_approved(mark_key)
  local state = get_state(self)
  state.approved[mark_key], state.removed[mark_key] = nil, true
  self:schedule_save()
end

-- The keys holding a record or a tombstone
local function held_keys(state)
  local held = {}
  for key in pairs(state.approved) do
    held[key] = true
  end
  for key in pairs(state.removed) do
    held[key] = true
  end
  return held
end

-- Copy approved records for `items` from other branches' reviews of the same
-- type, matched by change id, most recently used branch first. Returns true
-- if any were adopted. Objects are content-addressed, so the copied record
-- keeps its hash, and save() writes the object into this branch's store.
local function adopt_from_siblings(self, state, items)
  if #items == 0 or not self.repo_name then return false end

  -- Escape luv callback context to main Vim loop (required for vim.fn calls)
  loop.free_textlock()

  local adopted = false
  for _, sibling in ipairs(persistence.load_siblings(self.repo_name, self.branch_name, self.review_type)) do
    local entries = sibling.data.entries or {}
    -- Every key with a change id holds a record, so this doubles as the key set
    local change_ids = {}
    for key, entry in pairs(entries) do
      if type(entry) == 'table' and entry.approved then change_ids[key] = entry.change_id end
    end

    for _, match in ipairs(change_id_rekey.find(items, change_ids, change_ids)) do
      local record = read_record(self.repo_name, sibling.branch_name, entries[match.key])
      if record then state.approved[match.item.key], adopted = record, true end
    end

    items = change_id_rekey.unheld(items, state.approved)
    if #items == 0 then break end
  end
  return adopted
end

-- Reconcile stored records with the current (commit, file) `items`
-- (`{ key, filepath, change_id }`) by jj change id. Moves records orphaned by
-- a reworded subject, adopts matching records from other branches' reviews,
-- and records each item's change id so records approved later carry it. See
-- change_id_rekey.
function ReviewState:reconcile_change_ids(items)
  local state = get_state(self)

  -- Moves can chain or swap, so read every source before writing. Tombstones
  -- move with their key too.
  local moves = change_id_rekey.plan(items, held_keys(state), state.change_ids)
  local moved = {}
  for i, move in ipairs(moves) do
    moved[i] = { record = state.approved[move.from], removed = state.removed[move.from] }
    state.approved[move.from], state.removed[move.from], state.change_ids[move.from] = nil, nil, nil
  end
  for i, move in ipairs(moves) do
    state.approved[move.to], state.removed[move.to] = moved[i].record, moved[i].removed
  end

  local adopted = adopt_from_siblings(self, state, change_id_rekey.unheld(items, held_keys(state)))
  if #moves > 0 or adopted then self:schedule_save() end

  for _, item in ipairs(items) do
    state.change_ids[item.key] = item.change_id
  end
end

-- Reset the index for the current session (everything back to unseen)
function ReviewState:reset()
  local state = get_state(self)
  for key in pairs(state.approved) do
    state.removed[key] = true
  end
  for key in pairs(state.change_ids) do
    state.removed[key] = true
  end
  state.approved = {}
  self:schedule_save()
end

-- Store last viewed file for re-entry fallback (when current buffer is not in review)
-- commit_message: first line of commit message (stable across rebases, unlike hash)
-- focus: 'diff' or 'list' - which component had focus
function ReviewState:save_position(section, filepath, commit_message, focus)
  get_state(self).position = {
    section = section,
    filepath = filepath,
    commit_message = commit_message,
    focus = focus,
  }
end

-- Get last viewed file for re-entry fallback
-- Returns: section, filepath, commit_message, focus
function ReviewState:get_position()
  local pos = get_state(self).position
  return pos.section or 'unseen', pos.filepath, pos.commit_message, pos.focus
end

-- Write snapshot objects, then the JSON referencing them. The final save also
-- sweeps unreferenced objects and evicts stale branches; objects are immutable
-- and content-addressed, so unreferenced ones are harmless in between.
local function write_to_disk(self, final)
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
    entries[mark_key] = {
      approved = record.hash,
      deleted = record.deleted or nil,
      base = record.base_hash,
      change_id = state.change_ids[mark_key],
    }
    objects[record.hash] = record.lines
  end
  -- Tombstones only matter for adoption, which goes by change id
  for mark_key in pairs(state.removed) do
    local change_id = state.change_ids[mark_key]
    if change_id then entries[mark_key] = { change_id = change_id } end
  end

  -- Never write JSON referencing objects that failed to write
  local _, err = persistence.write_objects(self.repo_name, self.branch_name, objects)
  if not err then
    _, err = persistence.save(self.repo_name, self.branch_name, self.review_type, { entries = entries })
  end
  if err then
    console.warn(string.format('Failed to save review state: %s', err[1]))
    return
  end

  if final then
    persistence.sweep_objects(self.repo_name, self.branch_name)
    persistence.evict_lru(self.repo_name)
  end

  -- Our own write shouldn't trigger a reload on the next entry
  state.loaded = true
  state.disk_mtime = state_file_mtime(self)
end

-- Queue a write-behind save; mark mutators call this so approvals reach disk
-- without waiting for the screen to close.
function ReviewState:schedule_save()
  if self._save_timer then return end
  self._save_timer = vim.defer_fn(loop.coroutine(function()
    self._save_timer = nil
    write_to_disk(self, false)
  end), SAVE_DELAY_MS)
end

-- Save state to disk now, with sweep and eviction, superseding any queued
-- write-behind save. Position is session-only, never persisted.
function ReviewState:save()
  if self._save_timer then
    self._save_timer:stop()
    self._save_timer:close()
    self._save_timer = nil
  end
  write_to_disk(self, true)
end

return ReviewState
