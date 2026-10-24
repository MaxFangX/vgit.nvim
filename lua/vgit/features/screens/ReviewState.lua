local loop = require('vgit.core.loop')
local Object = require('vgit.core.Object')
local console = require('vgit.core.console')
local persistence = require('vgit.features.screens.review_persistence')
local record_keys = require('vgit.features.screens.record_keys')

--[[
  ReviewState holds a review's records: the approved snapshot of each
  reviewed file, by record key. It is keyed by (repo_key, branch_key,
  review_type), the identity of its state file, where review_type is
  'by_file' or 'by_commit'.

  A record is { lines = {...}, deleted = bool, base_lines = {...} } where
  base_lines is the base the approval was made against (used to rebase the
  snapshot when the base changes). No record means approved == base
  (nothing seen). Records persist to disk as content-addressed objects
  referenced from the review-type JSON file, each with the jj change id of
  its commit when known (see record_keys).

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
    branch_key = opts.branch_key,
    review_type = opts.review_type or 'by_file',
    repo_key = opts.repo_key,
    _loaded = false,           -- Whether state has been loaded from disk
    _skip_persistence = false, -- Set when the state file must not be overwritten
  }
end

function ReviewState:get_state_key()
  return string.format('%s|%s|%s', self.repo_key or '', self.branch_key or '', self.review_type)
end

local function get_state(self)
  local key = self:get_state_key()
  if not state_store[key] then
    state_store[key] = {
      records = {},
      change_ids = {},
      removed = {},
      -- Keys changed since the last write: they win over the file's version
      -- when another session wrote it meanwhile (sync_from_disk)
      dirty = {},
      position = { type = 'unseen' },
    }
  end
  return state_store[key]
end

local function state_stamp(self)
  return persistence.state_stamp(self.repo_key, self.branch_key, self.review_type)
end

-- An entry's approved record, materialized from `branch_key`'s object store,
-- or nil if its snapshot or base object is missing.
local function read_record(repo_key, branch_key, entry)
  local lines = persistence.read_object(repo_key, branch_key, entry.approved)
  local base_lines = entry.base and persistence.read_object(repo_key, branch_key, entry.base)
  if not lines or not base_lines then return nil end

  return {
    lines = lines,
    deleted = entry.deleted == true,
    base_lines = base_lines,
    -- Cache content hashes so save() doesn't re-hash unchanged records
    hash = entry.approved,
    base_hash = entry.base,
  }
end

-- Merge the state file into the store if another session wrote (or deleted)
-- it since this one last read or wrote it: every key this session hasn't
-- changed since (see `dirty`) takes the file's version. Returns nil, err if
-- the file must not be overwritten; then this session stops saving.
local function sync_from_disk(self, state)
  local disk_stamp = state_stamp(self)
  if disk_stamp == state.disk_stamp then return end

  -- Never prompt or delete: other sessions, possibly on other vgit
  -- versions, share the file. Leave a newer or unreadable file alone; a
  -- corrupt one is replaced by the next save.
  local data, err = persistence.load(self.repo_key, self.branch_key, self.review_type)
  if err and (err.newer or err.unreadable) then
    console.warn(string.format('%s; review progress will not be saved this session', err[1]))
    self._skip_persistence = true
    return nil, err
  end
  state.disk_stamp = disk_stamp
  if err then
    console.warn(string.format('Ignoring review state: %s', err[1]))
    return
  end

  -- No file means it was never saved, or deleted since: nothing is approved
  local entries, keys = data and data.entries or {}, {}
  for _, map in ipairs({ entries, state.records, state.removed }) do
    for key in pairs(map) do
      if not state.dirty[key] then keys[key] = true end
    end
  end

  local missing = 0
  for key in pairs(keys) do
    local entry, record = entries[key], state.records[key]
    if type(entry) == 'table' and entry.approved then
      local same = record
        and record.hash == entry.approved
        and record.base_hash == entry.base
        and record.deleted == (entry.deleted == true)
      if not same then
        -- A missing object means the snapshot was lost (the file reverts to
        -- unseen), unless this session still holds one
        record = read_record(self.repo_key, self.branch_key, entry) or record
        if not record then missing = missing + 1 end
      end
      state.records[key], state.removed[key] = record, nil
      state.change_ids[key] = state.change_ids[key] or entry.change_id
    elseif type(entry) == 'table' and entry.change_id then
      state.records[key], state.removed[key] = nil, true
      state.change_ids[key] = state.change_ids[key] or entry.change_id
    else
      state.records[key], state.removed[key] = nil, nil
    end
  end
  if missing > 0 then
    console.warn(string.format('Review state: %d approved snapshot(s) missing, files reset to unseen', missing))
  end
end

-- Load state from disk (call explicitly from coroutine context). Every save
-- goes through the in-session store, so it is the source of truth within a
-- session, and re-entering a review skips re-reading the object store,
-- unless the state file's stamp shows another session wrote it since we
-- last touched it.
function ReviewState:load_from_disk()
  if not self.repo_key or self._loaded then return end
  self._loaded = true

  local state = get_state(self)
  if state.disk_stamp == state_stamp(self) then return end

  -- Escape luv callback context to main Vim loop (required for vim.fn calls)
  loop.free_textlock()
  sync_from_disk(self, state)
end

-- The record for record_key: { lines, deleted, base_lines }, or nil
-- (approved == base, i.e. nothing seen)
function ReviewState:get_record(record_key)
  return get_state(self).records[record_key]
end

-- base_lines: the base content the approval was made against; lets the model
-- rebase the snapshot when the base later changes (stack restructuring).
-- Content hashes are computed lazily on save() and cached on the record.
function ReviewState:set_record(record_key, lines, deleted, base_lines)
  local state = get_state(self)
  -- Marking again against the same base keeps its hash, saving a rehash of
  -- the whole base on every save
  local previous = state.records[record_key]
  local base_hash = previous and rawequal(previous.base_lines, base_lines) and previous.base_hash or nil
  state.records[record_key] = {
    lines = lines,
    deleted = deleted == true,
    base_lines = base_lines,
    base_hash = base_hash,
  }
  state.removed[record_key], state.dirty[record_key] = nil, true
  self:schedule_save()
end

function ReviewState:remove_record(record_key)
  local state = get_state(self)
  state.records[record_key], state.removed[record_key], state.dirty[record_key] = nil, true, true
  self:schedule_save()
end

-- The keys holding a record or a tombstone
local function held_keys(state)
  local held = {}
  for key in pairs(state.records) do
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
  if #items == 0 or not self.repo_key then return false end

  -- Escape luv callback context to main Vim loop (required for vim.fn calls)
  loop.free_textlock()

  local adopted = false
  for _, sibling in ipairs(persistence.load_siblings(self.repo_key, self.branch_key, self.review_type)) do
    local entries = sibling.data.entries or {}
    local change_ids = {}
    for key, entry in pairs(entries) do
      if type(entry) == 'table' and entry.approved then change_ids[key] = entry.change_id end
    end

    for _, match in ipairs(record_keys.find(items, change_ids)) do
      local record = read_record(self.repo_key, sibling.branch_key, entries[match.key])
      if record then
        state.records[match.item.key], state.dirty[match.item.key], adopted = record, true, true
      end
    end

    items = record_keys.unheld(items, state.records)
    if #items == 0 then break end
  end
  return adopted
end

-- Reconcile stored records with the current (commit, file) `items`
-- (`{ key, filepath, change_id }`) by jj change id. Moves records orphaned by
-- a reworded subject, adopts matching records from other branches' reviews,
-- and records each item's change id so records approved later carry it. See
-- record_keys.
function ReviewState:reconcile_change_ids(items)
  local state = get_state(self)

  -- Moves can chain or swap, so read every source before writing. Tombstones
  -- move with their key too.
  local moves = record_keys.plan(items, held_keys(state), state.change_ids)
  local moved = {}
  for i, move in ipairs(moves) do
    moved[i] = { record = state.records[move.from], removed = state.removed[move.from] }
    state.records[move.from], state.removed[move.from], state.change_ids[move.from] = nil, nil, nil
  end
  for i, move in ipairs(moves) do
    state.records[move.to], state.removed[move.to] = moved[i].record, moved[i].removed
    state.dirty[move.from], state.dirty[move.to] = true, true
  end

  local adopted = adopt_from_siblings(self, state, record_keys.unheld(items, held_keys(state)))
  if #moves > 0 or adopted then self:schedule_save() end

  for _, item in ipairs(items) do
    state.change_ids[item.key] = item.change_id
  end
end

-- Reset the review (everything back to unseen)
function ReviewState:reset()
  local state = get_state(self)
  for key in pairs(held_keys(state)) do
    state.removed[key], state.dirty[key] = true, true
  end
  for key in pairs(state.change_ids) do
    state.removed[key], state.dirty[key] = true, true
  end
  state.records = {}
  self:schedule_save()
end

-- The last viewed spot, for re-entry when the current buffer isn't in the
-- review: { type = 'seen'|'unseen', filepath, commit_message, focus }, where
-- commit_message is the subject (stable across rebases, unlike the hash) and
-- focus is 'diff' or 'list'. Session-only, never persisted.
function ReviewState:set_position(position)
  get_state(self).position = position
end

function ReviewState:get_position()
  return get_state(self).position
end

-- Write snapshot objects, then the JSON referencing them. The final save also
-- sweeps unreferenced objects and evicts stale branches; objects are immutable
-- and content-addressed, so unreferenced ones are harmless in between.
--
-- Interleavings. Within one nvim, this yields once, at free_textlock, before
-- it reads the store, and never after, so marks can't interleave with a
-- write: a write-behind save racing the final save() writes the current
-- store whichever runs first. Other sessions may write the same file at any
-- time, so right before writing the JSON, the file is merged in if it
-- changed since this session last read or wrote it (sync_from_disk). Each
-- writer renames its own temp file into place, and the stamp recorded is
-- that of the file this session wrote, so a write landing just after ours is
-- merged next time rather than overwritten. Two sessions writing within the
-- same few milliseconds can still lose one's changes; that isn't worth a lock
-- for interactive use.
local function write_to_disk(self, final)
  if not self.repo_key or self._skip_persistence then return end

  -- Escape luv callback context to main Vim loop (required for vim.fn calls)
  loop.free_textlock()
  local state = get_state(self)

  -- Records are immutable once set (set_record replaces them wholesale),
  -- so cached hashes stay valid; only records new this session get hashed.
  local objects = {}
  for _, record in pairs(state.records) do
    record.hash = record.hash or persistence.hash_lines(record.lines)
    record.base_hash = record.base_hash or persistence.hash_lines(record.base_lines)
    objects[record.hash], objects[record.base_hash] = record.lines, record.base_lines
  end

  -- Never write JSON referencing objects that failed to write. Records merged
  -- in from the file have their objects on disk already.
  local _, err = persistence.write_objects(self.repo_key, self.branch_key, objects)
  if err then
    console.warn(string.format('Failed to save review state: %s', err[1]))
    return
  end
  _, err = sync_from_disk(self, state)
  if err then return end

  local entries = {}
  for record_key, record in pairs(state.records) do
    entries[record_key] = {
      approved = record.hash,
      deleted = record.deleted or nil,
      base = record.base_hash,
      change_id = state.change_ids[record_key],
    }
  end
  -- Tombstones only matter for adoption, which goes by change id
  for record_key in pairs(state.removed) do
    local change_id = state.change_ids[record_key]
    if change_id then entries[record_key] = { change_id = change_id } end
  end

  local written
  written, err = persistence.save(self.repo_key, self.branch_key, self.review_type, { entries = entries })
  if err then
    console.warn(string.format('Failed to save review state: %s', err[1]))
    return
  end
  state.dirty, state.disk_stamp = {}, written

  if final then
    persistence.sweep_objects(self.repo_key, self.branch_key)
    persistence.evict_lru(self.repo_key)
  end
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
-- write-behind save.
function ReviewState:save()
  if self._save_timer then
    self._save_timer:stop()
    self._save_timer:close()
    self._save_timer = nil
  end
  write_to_disk(self, true)
end

return ReviewState
