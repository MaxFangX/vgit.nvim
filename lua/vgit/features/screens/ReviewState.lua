local fs = require('vgit.core.fs')
local utils = require('vgit.core.utils')
local Object = require('vgit.core.Object')

--[[
  ReviewState manages the seen/unseen state for PR review workflows.

  State is keyed by: (base_branch, branch_name, review_type)
  where review_type is 'by_file' or 'by_commit'.

  All mark operations use a unified key-based API. The key is provided by
  callers - typically the filename. Marks use content-based identifiers
  (SHA-256 hashes of hunk content) so they persist when hunks shift position.
]]

local ReviewState = Object:extend()

-- Create a status object that mimics GitStatus for display in list views
function ReviewState.create_status(filename, file_status, old_filename)
  local filetype = fs.detect_filetype(filename)
  local status_char = file_status or 'M'

  return {
    id = utils.math.uuid(),
    value = status_char .. ' ',
    first = status_char,
    second = ' ',
    filename = filename,
    old_filename = old_filename,
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
-- Each key maps to { marks = {}, position = { section, filename, cursor_lnum } }
local state_store = {}

function ReviewState:constructor(opts)
  opts = opts or {}

  return {
    base_branch = opts.base_branch,
    branch_name = opts.branch_name,
    review_type = opts.review_type or 'by_file',
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
    state_store[key] = { marks = {}, position = { section = 'unseen' }, hunk_counts = {}, content_ids = {} }
  end
  return state_store[key]
end

-- Get or create the marks table for current session
function ReviewState:get_marks()
  return get_state(self).marks
end

-- Generate a mark key from entry key and content id (or hunk index for legacy)
local function mark_key(entry_key, hunk_id)
  return string.format('%s:%s', entry_key, hunk_id)
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
end

-- Unmark a hunk
function ReviewState:unmark_hunk(key, content_id)
  local marks = self:get_marks()
  marks[mark_key(key, content_id)] = nil
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
end

-- Clear cached content_ids (call when HEAD may have changed)
-- Marks persist, but content_ids will be recomputed from fresh diffs
function ReviewState:clear_content_ids()
  local state = get_state(self)
  state.content_ids = {}
end

-- Store last position for re-entry (persisted in state_store)
function ReviewState:save_position(section, filename, cursor_lnum)
  local state = get_state(self)
  state.position = {
    section = section,
    filename = filename,
    cursor_lnum = cursor_lnum,
  }
end

-- Get last position for re-entry
function ReviewState:get_position()
  local pos = get_state(self).position
  return pos.section or 'unseen', pos.filename, pos.cursor_lnum
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

return ReviewState
