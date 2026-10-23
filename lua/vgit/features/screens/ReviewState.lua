local fs = require('vgit.core.fs')
local loop = require('vgit.core.loop')
local utils = require('vgit.core.utils')
local Object = require('vgit.core.Object')
local persistence = require('vgit.features.screens.ReviewStatePersistence')
local change_id_rekey = require('vgit.features.screens.change_id_rekey')

--[[
  ReviewState manages the seen/unseen state for PR review workflows.

  State is keyed by: (base_branch, branch_name, review_type)
  where review_type is 'by_file' or 'by_commit'.

  All mark operations use a unified key-based API. The key is provided by
  callers - typically the filepath. Marks use content-based identifiers
  (FNV-1a hashes of hunk content) so they persist when hunks shift position.
  By-commit keys also record their commit's jj change id when known (see
  change_id_rekey).
]]

local ReviewState = Object:extend()

-- Write-behind delay: a burst of marks coalesces into one save shortly after
-- it settles, so a crash or kill mid-review loses at most this much work.
local SAVE_DEBOUNCE_MS = 1000

-- Create a status object that mimics GitStatus for display in list views
function ReviewState.create_status(filepath, file_status, old_filepath)
  local filetype = fs.detect_filetype(filepath)
  local status_char = file_status or 'M'

  return {
    id = utils.math.uuid(),
    value = status_char .. ' ',
    first = status_char,
    second = ' ',
    filepath = filepath,
    old_filepath = old_filepath,
    filetype = filetype,
    is_staged = function() return false end,
    is_unstaged = function() return true end,
    is_unmerged = function() return false end,
    has = function(_, s)
      local f = s:sub(1, 1)
      if f == '*' then return true end
      return f == status_char
    end,
    has_either = function(_, s)
      local f, sec = s:sub(1, 1), s:sub(2, 2)
      return f == status_char or sec == ' '
    end,
    has_both = function(_, s)
      local f, sec = s:sub(1, 1), s:sub(2, 2)
      return f == status_char and sec == ' '
    end,
  }
end

-- Global state storage (persists across screen instances within a Vim session)
-- Each key maps to { marks = {}, position = { section, filepath, cursor_lnum } }
local state_store = {}

function ReviewState:constructor(opts)
  opts = opts or {}

  return {
    base_branch = opts.base_branch,
    branch_name = opts.branch_name,
    review_type = opts.review_type or 'by_file',
    repo_name = opts.repo_name,     -- Repo name for persistence (from origin or dir name)
    _loaded = false,                -- Whether state has been loaded from disk
    _skip_persistence = false,      -- Set if user declines to delete corrupted state
  }
end

-- Generate the state key for the current review session
function ReviewState:get_state_key()
  return string.format('%s|%s|%s', self.base_branch or '', self.branch_name or '', self.review_type)
end

-- Get or create the state for current session
local function get_state(self)
  local key = self:get_state_key()
  if not state_store[key] then
    state_store[key] = {
      marks = {},
      change_ids = {},
      position = { section = 'unseen' },
      hunk_counts = {},
      content_ids = {},
    }
  end
  return state_store[key]
end

-- Load state from disk (call explicitly from coroutine context)
function ReviewState:load_from_disk()
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
  elseif data then
    -- Restore persisted state from disk (position is session-only, never persisted)
    local key = self:get_state_key()
    local existing = state_store[key]
    state_store[key] = {
      marks = data.marks or {},
      change_ids = data.changeIds or {},
      position = existing and existing.position or { section = 'unseen' },
      hunk_counts = data.hunkCounts or {},
      content_ids = data.contentIds or {},
    }
  end
end

-- Get or create the marks table for current session
function ReviewState:get_marks()
  return get_state(self).marks
end

-- Generate a mark key from entry key and content id (or hunk index for legacy)
local function mark_key(entry_key, hunk_id)
  return string.format('%s:%s', entry_key, hunk_id)
end

-- The content ids of the marks under each entry key, found by splitting each
-- mark key at its last colon.
local function marks_by_key(marks)
  local grouped = {}
  for composite in pairs(marks) do
    local key, content_id = composite:match('^(.*):([^:]*)$')
    if key then
      local ids = grouped[key] or {}
      ids[#ids + 1] = content_id
      grouped[key] = ids
    end
  end
  return grouped
end

-- Copy marks for `items` from other branches' reviews of the same type,
-- matched by change id, most recently used branch first, recording adopted
-- keys in `held`. Returns true if any were adopted.
local function adopt_from_siblings(self, state, items, held)
  if #items == 0 or not self.repo_name then return false end

  -- Escape luv callback context to main Vim loop (required for vim.fn calls)
  loop.free_textlock()

  local adopted = false
  for _, sibling in ipairs(persistence.load_siblings(self.repo_name, self.branch_name, self.review_type)) do
    local sibling_marks = marks_by_key(sibling.data.marks or {})
    for _, match in ipairs(change_id_rekey.find(items, sibling_marks, sibling.data.changeIds or {})) do
      for _, content_id in ipairs(sibling_marks[match.key]) do
        state.marks[mark_key(match.item.key, content_id)] = true
      end
      held[match.item.key], adopted = sibling_marks[match.key], true
    end

    items = change_id_rekey.unheld(items, held)
    if #items == 0 then break end
  end
  return adopted
end

-- Reconcile stored marks with the current (commit, file) `items`
-- (`{ key, filepath, change_id }`) by jj change id. Moves marks orphaned by a
-- reworded subject, adopts matching marks from other branches' reviews, and
-- records each item's change id so marks made later carry it. See
-- change_id_rekey.
function ReviewState:reconcile_change_ids(items)
  local state = get_state(self)

  local held = marks_by_key(state.marks)
  local moves = change_id_rekey.plan(items, held, state.change_ids)
  for _, move in ipairs(moves) do
    -- `or {}`: a divergent change id can plan two moves from one key
    for _, content_id in ipairs(held[move.from] or {}) do
      state.marks[mark_key(move.from, content_id)] = nil
      state.marks[mark_key(move.to, content_id)] = true
    end
    held[move.to], held[move.from] = held[move.from], nil
    state.change_ids[move.from] = nil
  end

  local adopted = adopt_from_siblings(self, state, change_id_rekey.unheld(items, held), held)
  if #moves > 0 or adopted then self:schedule_save() end

  for _, item in ipairs(items) do
    state.change_ids[item.key] = item.change_id
  end
end

-- Check if a hunk is marked as seen
function ReviewState:is_hunk_seen(key, content_id)
  local marks = self:get_marks()
  return marks[mark_key(key, content_id)] == true
end

-- Mark a hunk as seen
function ReviewState:mark_hunk(key, content_id)
  local marks = self:get_marks()
  marks[mark_key(key, content_id)] = true
  self:schedule_save()
end

-- Unmark a hunk
function ReviewState:unmark_hunk(key, content_id)
  local marks = self:get_marks()
  marks[mark_key(key, content_id)] = nil
  self:schedule_save()
end

-- Mark all hunks as seen (takes array of content_ids)
function ReviewState:mark_all_hunks(key, content_ids)
  for _, content_id in ipairs(content_ids) do
    self:mark_hunk(key, content_id)
  end
end

-- Unmark all hunks (takes array of content_ids)
function ReviewState:unmark_all_hunks(key, content_ids)
  for _, content_id in ipairs(content_ids) do
    self:unmark_hunk(key, content_id)
  end
end

-- Check if an entry has any seen hunks
-- content_ids: optional array of content_ids for accurate check
-- Without content_ids, returns false (conservative: can't verify what's seen)
function ReviewState:has_seen_hunks(key, content_ids)
  -- If we have content_ids, check each one for accuracy
  if content_ids and #content_ids > 0 then
    for _, content_id in ipairs(content_ids) do
      if self:is_hunk_seen(key, content_id) then
        return true
      end
    end
    return false
  end

  -- Without content_ids, assume nothing is seen (conservative)
  return false
end

-- Check if an entry has any unseen hunks
-- content_ids: optional array of content_ids for accurate check
-- Without content_ids, returns true (conservative: assumes unseen hunks exist)
function ReviewState:has_unseen_hunks(key, content_ids)
  -- If we have content_ids, check each one for accuracy
  if content_ids and #content_ids > 0 then
    for _, content_id in ipairs(content_ids) do
      if not self:is_hunk_seen(key, content_id) then
        return true
      end
    end
    return false
  end

  -- Without content_ids, assume there might be unseen hunks
  -- (Conservative approach until diff is loaded)
  return true
end

-- Get count of seen hunks (takes array of content_ids)
function ReviewState:get_seen_hunk_count(key, content_ids)
  local count = 0
  for _, content_id in ipairs(content_ids) do
    if self:is_hunk_seen(key, content_id) then
      count = count + 1
    end
  end
  return count
end

-- Reset all marks for the current session
function ReviewState:reset()
  local state = get_state(self)
  state.marks = {}
  self:schedule_save()
end

-- Clear cached content_ids (call when HEAD may have changed)
-- Marks persist, but content_ids will be recomputed from fresh diffs
function ReviewState:clear_content_ids()
  local state = get_state(self)
  state.content_ids = {}
end

-- Store last viewed file for re-entry fallback (when current buffer is not in review)
-- commit_message: first line of commit message (stable across rebases, unlike hash)
-- focus: 'diff' or 'list' - which component had focus
function ReviewState:save_position(section, filepath, commit_message, focus)
  local state = get_state(self)
  state.position = {
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

-- Store hunk count for an entry
function ReviewState:set_hunk_count(key, count)
  local state = get_state(self)
  state.hunk_counts[key] = count
end

-- Get stored hunk count for an entry
function ReviewState:get_hunk_count(key)
  return get_state(self).hunk_counts[key]
end

-- Store content_ids for an entry (persists across screen re-entry)
function ReviewState:set_content_ids(key, content_ids)
  local state = get_state(self)
  state.content_ids[key] = content_ids
end

-- Get stored content_ids for an entry
function ReviewState:get_content_ids(key)
  return get_state(self).content_ids[key]
end

-- Write marks and their caches to the review-type JSON file. The final save
-- also evicts stale branches.
local function write_to_disk(self, final)
  if not self.repo_name or self._skip_persistence then return end

  -- Escape luv callback context to main Vim loop (required for vim.fn calls)
  loop.free_textlock()
  local state = get_state(self)

  -- Unmarked keys hold change ids only for marks made later this session, so
  -- persist just the change ids of keys holding marks.
  local change_ids = {}
  for key in pairs(marks_by_key(state.marks)) do
    change_ids[key] = state.change_ids[key]
  end

  local data = {
    marks = state.marks,
    changeIds = change_ids,
    hunkCounts = state.hunk_counts,
    contentIds = state.content_ids,
  }
  persistence.save(self.repo_name, self.branch_name, self.review_type, data)
  if final then
    persistence.evict_lru(self.repo_name)
  end
end

-- Queue a write-behind save; mark mutators call this so marks reach disk
-- without waiting for the screen to close.
function ReviewState:schedule_save()
  if not self._debounced_save then
    self._debounced_save = loop.debounce_coroutine(function() write_to_disk(self, false) end, SAVE_DEBOUNCE_MS)
  end
  self._debounced_save()
end

-- Save state to disk now, with eviction, superseding any queued write-behind
-- save. Position is session-only, not persisted.
function ReviewState:save()
  if self._debounced_save then
    loop.close_debounced(self._debounced_save)
    self._debounced_save = nil
  end
  write_to_disk(self, true)
end

return ReviewState
