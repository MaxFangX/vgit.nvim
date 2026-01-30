local Diff = require('vgit.core.Diff')
local loop = require('vgit.core.loop')
local Object = require('vgit.core.Object')

--[[
  BaseReviewModel contains shared logic for review models.

  Subclasses must implement:
    - get_entry_key(entry) - returns the key for ReviewState
    - get_review_type() - returns 'by_file' or 'by_commit'
    - fetch(base_branch_arg) - fetches commits/files
    - rebuild_entries() - builds the entry structure
    - get_full_diff(key) - gets the unfiltered diff for a key
    - get_diff_args(entry) - returns args for get_full_diff from entry
]]

local BaseReviewModel = Object:extend()

function BaseReviewModel:constructor(opts)
  return {
    state = {
      id = nil,
      diffs = {},
      entries = nil,
      reponame = nil,
      base_branch = nil,
      merge_base = nil,
      head_hash = nil,
      list_entries = {},
      hunk_counts = {},
      layout_type = opts.layout_type or 'unified',
    },
    review_state = nil,
  }
end

function BaseReviewModel:get_layout_type()
  return self.state.layout_type
end

function BaseReviewModel:get_review_state()
  return self.review_state
end

function BaseReviewModel:set_entry_id(id)
  self.state.id = id
end

function BaseReviewModel:get_entry(id)
  if id then self.state.id = id end
  return self.state.list_entries[self.state.id]
end

function BaseReviewModel:get_entries()
  return self.state.entries
end

function BaseReviewModel:get_filename()
  local entry = self:get_entry()
  if not entry then return nil end
  return entry.filename
end

function BaseReviewModel:get_filepath()
  local reponame = self.state.reponame
  local filename = self:get_filename()
  if not filename then return nil end

  return string.format('%s/%s', reponame, filename)
end

function BaseReviewModel:get_filetype()
  local entry = self:get_entry()
  if not entry then return nil end
  return entry.status.filetype
end

-- Get hunk count for a key (uses cache, then ReviewState)
-- Returns nil if not computed yet - use ensure_hunk_count(entry) to compute
function BaseReviewModel:get_hunk_count(key)
  -- Return local cached count if available
  if self.state.hunk_counts[key] then
    return self.state.hunk_counts[key]
  end

  -- Check ReviewState for persisted count (survives re-entry)
  local persisted = self.review_state:get_hunk_count(key)
  if persisted then
    self.state.hunk_counts[key] = persisted
    return persisted
  end

  return nil
end

-- Ensure hunk count is computed for an entry (calls get_full_diff to populate cache)
function BaseReviewModel:ensure_hunk_count(entry)
  local key = self:get_entry_key(entry)
  if self.state.hunk_counts[key] then
    return self.state.hunk_counts[key]
  end

  -- Compute by calling get_full_diff (which caches the count)
  -- Temporarily set entry id so get_full_diff can access entry data
  local saved_id = self.state.id
  self.state.id = entry.id
  self:get_full_diff(self:get_diff_args(entry))
  self.state.id = saved_id

  return self.state.hunk_counts[key]
end

-- Store hunk count in both local cache and ReviewState
function BaseReviewModel:set_hunk_count(key, count)
  self.state.hunk_counts[key] = count
  self.review_state:set_hunk_count(key, count)
end

-- Get filtered diff based on entry type (seen/unseen)
function BaseReviewModel:get_diff()
  local entry = self:get_entry()
  if not entry then return nil, { 'entry not found' } end

  local key = self:get_entry_key(entry)
  local entry_type = entry.type -- 'seen' or 'unseen'

  -- Get the full diff first
  local full_diff, err = self:get_full_diff(self:get_diff_args(entry))
  if err then return nil, err end
  if not full_diff then return nil end

  -- Filter hunks based on entry type
  local full_hunks = full_diff.hunks or {}
  local total_hunks = #full_hunks > 0 and #full_hunks or 1
  local filtered_indices = {}

  for i = 1, total_hunks do
    local is_seen = self.review_state:is_hunk_seen(key, i)
    if (entry_type == 'seen' and is_seen) or (entry_type == 'unseen' and not is_seen) then
      filtered_indices[#filtered_indices + 1] = i
    end
  end

  -- If no hunks match the filter, show empty diff
  if #filtered_indices == 0 then
    local empty_diff = Diff()
    empty_diff.original_indices = {}
    empty_diff.entry_type = entry_type
    return empty_diff
  end

  -- If all hunks match, return a wrapper with the index mapping
  -- (Don't mutate the cached full_diff - it's shared across entry types)
  if #filtered_indices == total_hunks then
    return {
      hunks = full_diff.hunks,
      marks = full_diff.marks,
      lines = full_diff.lines,
      lnum_changes = full_diff.lnum_changes,
      current_lines = full_diff.current_lines,
      previous_lines = full_diff.previous_lines,
      stat = full_diff.stat,
      original_indices = filtered_indices,
      entry_type = entry_type,
    }
  end

  -- Build filtered hunks list
  local filtered_hunks = {}
  for _, orig_idx in ipairs(filtered_indices) do
    filtered_hunks[#filtered_hunks + 1] = full_hunks[orig_idx]
  end

  -- Use stored original data (avoid async git_show.lines call)
  local original_lines = full_diff._original_lines or {}
  local is_deleted = full_diff._is_deleted or false
  local layout_type = self:get_layout_type()

  -- Generate a new diff with only the filtered hunks
  local filtered_diff = Diff():generate(filtered_hunks, original_lines, layout_type, { is_deleted = is_deleted })

  -- Store the mapping from filtered index to original index
  filtered_diff.original_indices = filtered_indices
  filtered_diff.entry_type = entry_type

  return filtered_diff
end

-- Mark operations using unified key-based API
function BaseReviewModel:mark_hunk(key, hunk_index)
  if not self.review_state then return end
  self.review_state:mark_hunk(key, hunk_index)
  self:rebuild_entries()
end

function BaseReviewModel:unmark_hunk(key, hunk_index)
  if not self.review_state then return end
  self.review_state:unmark_hunk(key, hunk_index)
  self:rebuild_entries()
end

function BaseReviewModel:mark_file(key)
  if not self.review_state then return end
  -- Ensure hunk count is computed (current entry should already be set by caller)
  local entry = self:get_entry()
  local total_hunks = entry and self:ensure_hunk_count(entry) or self:get_hunk_count(key)
  if not total_hunks then return end
  self.review_state:mark_all_hunks(key, total_hunks)
  self:rebuild_entries()
end

function BaseReviewModel:unmark_file(key)
  if not self.review_state then return end
  -- Ensure hunk count is computed (current entry should already be set by caller)
  local entry = self:get_entry()
  local total_hunks = entry and self:ensure_hunk_count(entry) or self:get_hunk_count(key)
  if not total_hunks then return end
  self.review_state:unmark_all_hunks(key, total_hunks)
  self:rebuild_entries()
end

function BaseReviewModel:is_hunk_seen(key, hunk_index)
  if not self.review_state then return false end
  return self.review_state:is_hunk_seen(key, hunk_index)
end

function BaseReviewModel:reset_marks()
  if not self.review_state then return end
  self.review_state:reset()
  self:rebuild_entries()
end

-- Abstract methods - subclasses must implement
function BaseReviewModel:get_entry_key(entry)
  error('get_entry_key must be implemented by subclass')
end

function BaseReviewModel:get_review_type()
  error('get_review_type must be implemented by subclass')
end

function BaseReviewModel:fetch(base_branch_arg)
  error('fetch must be implemented by subclass')
end

function BaseReviewModel:rebuild_entries()
  error('rebuild_entries must be implemented by subclass')
end

function BaseReviewModel:get_full_diff(...)
  error('get_full_diff must be implemented by subclass')
end

function BaseReviewModel:get_diff_args(entry)
  error('get_diff_args must be implemented by subclass')
end

return BaseReviewModel
