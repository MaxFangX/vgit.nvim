local fs = require('vgit.core.fs')
local utils = require('vgit.core.utils')
local Object = require('vgit.core.Object')

--[[
  ReviewState manages the seen/unseen state for PR review workflows.

  State is keyed by: (base_branch, HEAD_commit_hash, review_type)
  where review_type is 'by_file' or 'by_commit'.

  All mark operations use a unified key-based API. The key is provided by
  callers - for by_file mode it's the filename, for by_commit mode it's
  "commit_hash:filename".
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
    head_hash = opts.head_hash,
    review_type = opts.review_type or 'by_file',
  }
end

-- Generate the state key for the current review session
function ReviewState:get_state_key()
  return string.format('%s|%s|%s', self.base_branch or '', self.head_hash or '', self.review_type)
end

-- Get or create the state for current session
local function get_state(self)
  local key = self:get_state_key()
  if not state_store[key] then
    state_store[key] = { marks = {}, position = { section = 'unseen' }, hunk_counts = {} }
  end
  return state_store[key]
end

-- Get or create the marks table for current session
function ReviewState:get_marks()
  return get_state(self).marks
end

-- Generate a mark key from entry key and hunk index
local function mark_key(entry_key, hunk_index)
  return string.format('%s:%d', entry_key, hunk_index)
end

-- Check if a hunk is marked as seen
function ReviewState:is_hunk_seen(key, hunk_index)
  local marks = self:get_marks()
  return marks[mark_key(key, hunk_index)] == true
end

-- Mark a hunk as seen
function ReviewState:mark_hunk(key, hunk_index)
  local marks = self:get_marks()
  marks[mark_key(key, hunk_index)] = true
end

-- Unmark a hunk
function ReviewState:unmark_hunk(key, hunk_index)
  local marks = self:get_marks()
  marks[mark_key(key, hunk_index)] = nil
end

-- Mark all hunks as seen
function ReviewState:mark_all_hunks(key, total_hunks)
  for i = 1, total_hunks do
    self:mark_hunk(key, i)
  end
end

-- Unmark all hunks
function ReviewState:unmark_all_hunks(key, total_hunks)
  for i = 1, total_hunks do
    self:unmark_hunk(key, i)
  end
end

-- Check if an entry has any seen hunks
-- Optimized: scans marks instead of iterating 1..total_hunks
function ReviewState:has_seen_hunks(key)
  local marks = self:get_marks()
  local prefix = key .. ':'
  for k in pairs(marks) do
    if k:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

-- Check if an entry has any unseen hunks
-- If total_hunks not provided, returns true (assumes at least 1 hunk exists)
function ReviewState:has_unseen_hunks(key, total_hunks)
  local marks = self:get_marks()
  local prefix = key .. ':'

  -- Count marked hunks for this entry
  local marked_count = 0
  for k in pairs(marks) do
    if k:sub(1, #prefix) == prefix then
      marked_count = marked_count + 1
    end
  end

  -- If no marks, definitely has unseen hunks
  if marked_count == 0 then
    return true
  end

  -- If we know total_hunks, check if all are marked
  if total_hunks then
    return marked_count < total_hunks
  end

  -- Without total_hunks, assume there might be unseen hunks
  return true
end

-- Get count of seen hunks
function ReviewState:get_seen_hunk_count(key, total_hunks)
  local count = 0
  for i = 1, total_hunks do
    if self:is_hunk_seen(key, i) then
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

return ReviewState
