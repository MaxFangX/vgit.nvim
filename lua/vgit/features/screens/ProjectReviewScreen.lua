local fs = require('vgit.core.fs')
local Scene = require('vgit.ui.Scene')
local loop = require('vgit.core.loop')
local event = require('vgit.core.event')
local utils = require('vgit.core.utils')
local Buffer = require('vgit.core.Buffer')
local Object = require('vgit.core.Object')
local Window = require('vgit.core.Window')
local console = require('vgit.core.console')
local DiffView = require('vgit.ui.views.DiffView')
local KeyHelpBarView = require('vgit.ui.views.KeyHelpBarView')

--[[
  ProjectReviewScreen is the base class for review screens
  (ProjectReviewByFileScreen and ProjectReviewByCommitScreen).

  Subclasses must:
    - Set self.list_view in constructor
    - Set self.setting in constructor
]]

local ProjectReviewScreen = Object:extend()

function ProjectReviewScreen:constructor(opts)
  opts = opts or {}
  local scene = Scene()

  return {
    name = 'Project Review Screen',
    scene = scene,
    model = nil,      -- Set by subclass
    setting = nil,    -- Set by subclass
    list_view = nil,  -- Set by subclass
    diff_keymaps = {},
    app_bar_view = nil,
    diff_view = nil,
    _marking = false,     -- Lock to prevent concurrent mark operations
    _navigating = false,  -- Lock to prevent concurrent commit navigation
  }
end

-- Update commit message view if present (scheduled to escape fast event context)
function ProjectReviewScreen:update_commit_message()
  if not self.commit_message_view then return end
  local view = self.commit_message_view
  vim.schedule(function() view:render() end)
end

-- Initialize views (called by subclass after setting model and setting)
function ProjectReviewScreen:init_views(list_plot, diff_plot)
  local model = self.model
  local setting = self.setting

  self.app_bar_view = KeyHelpBarView(self.scene, {
    keymaps = function()
      local keymaps = setting:get('keymaps')
      return {
        { 'Mark hunk',   keymaps['mark_hunk'] },
        { 'Mark file',   keymaps['mark_file'] },
        { 'Unmark hunk', keymaps['unmark_hunk'] },
        { 'Unmark file', keymaps['unmark_file'] },
        { 'Reset',       keymaps['reset'] },
        { 'Next',        keymaps['next'] },
        { 'Previous',    keymaps['previous'] },
      }
    end,
  })

  self.diff_view = DiffView(self.scene, {
    layout_type = function()
      return model:get_layout_type()
    end,
    filename = function()
      return model:get_filename()
    end,
    filetype = function()
      return model:get_filetype()
    end,
    diff = function()
      return model:get_diff()
    end,
  }, diff_plot, {
    elements = {
      header = true,
      footer = false,
    },
  })
end

function ProjectReviewScreen:move_to(query_fn)
  return self.list_view:move_to(query_fn)
end

-- Find which mark (hunk) the cursor is currently on
-- Returns (filtered_index, total_filtered_marks) or (nil, 0) if no marks
function ProjectReviewScreen:get_mark_at_cursor()
  local diff = self.model:get_diff()
  if not diff or not diff.marks or #diff.marks == 0 then
    return nil, 0
  end

  local marks = diff.marks
  -- Subtract tabline padding to match how marks are indexed (see DiffView:get_current_mark_under_cursor)
  local padding = self.diff_view:get_tabline_padding()
  local lnum = self.diff_view.scene:get('current'):get_lnum() - padding

  for i, mark in ipairs(marks) do
    if lnum >= mark.top and lnum <= mark.bot then
      return i, #marks
    elseif mark.top > lnum then
      return math.max(1, i - 1), #marks
    end
  end

  return #marks, #marks
end

-- Get entry context with keys for ReviewState operations
function ProjectReviewScreen:get_entry_context(entry)
  return {
    key = self.model:get_entry_key(entry),       -- For entry identification and diff caching
    mark_key = self.model:get_mark_key(entry),   -- For mark storage (filename only)
    filename = entry.filename,
    commit_hash = entry.commit_hash, -- nil for by-file review
  }
end

-- Returns (original_hunk_index, total_original_hunks)
-- The original index is used for marking operations
function ProjectReviewScreen:get_current_mark_index()
  loop.free_textlock()
  local diff = self.model:get_diff()

  -- Binary files have no marks in the diff but should be treated as a single hunk
  if not diff or not diff.marks or #diff.marks == 0 then
    local entry = self.model:get_entry()
    if entry then
      local hunk_count = self.model:ensure_hunk_count(entry)
      if hunk_count and hunk_count > 0 then
        return 1, hunk_count
      end
    end
    return nil, 0
  end

  local filtered_index, _ = self:get_mark_at_cursor()
  if not filtered_index then
    return nil, 0
  end

  -- Map filtered index to original index if mapping exists
  local original_indices = diff.original_indices
  if original_indices and original_indices[filtered_index] then
    local entry = self.model:get_entry()
    if not entry then return filtered_index, #diff.marks end
    local total_original = self.model:ensure_hunk_count(entry)
    return original_indices[filtered_index], total_original or #diff.marks
  end

  return filtered_index, #diff.marks
end

function ProjectReviewScreen:move_to_next_file()
  loop.free_textlock()

  -- Try commit-aware navigation first (handles cross-commit navigation)
  local seen_result, wrapped = self:navigate_commit_aware('next')
  if seen_result then
    if wrapped then self:scroll_list_to_top() end
    return seen_result
  end

  -- Fall back to standard visible-item navigation
  local component = self.list_view.scene:get('list')
  local current_lnum = component:get_lnum()
  local count = component:get_line_count()

  for offset = 1, count do
    local target_lnum = current_lnum + offset
    local did_wrap = target_lnum > count
    if did_wrap then target_lnum = target_lnum - count end

    local item = self.list_view:get_list_item(target_lnum)
    if item and item.entry and item.entry.status then
      component:unlock():set_lnum(target_lnum):lock()
      if did_wrap then self:scroll_list_to_top() end
      return item
    end
  end
  return nil
end

function ProjectReviewScreen:move_to_prev_file()
  loop.free_textlock()

  -- Try commit-aware navigation first (handles cross-commit navigation)
  local seen_result, wrapped = self:navigate_commit_aware('prev')
  if seen_result then
    if wrapped then self:scroll_list_to_bottom() end
    return seen_result
  end

  -- Fall back to standard visible-item navigation
  local component = self.list_view.scene:get('list')
  local current_lnum = component:get_lnum()
  local count = component:get_line_count()

  for offset = 1, count do
    local target_lnum = current_lnum - offset
    local did_wrap = target_lnum < 1
    if did_wrap then target_lnum = target_lnum + count end

    local item = self.list_view:get_list_item(target_lnum)
    if item and item.entry and item.entry.status then
      component:unlock():set_lnum(target_lnum):lock()
      if did_wrap then self:scroll_list_to_bottom() end
      return item
    end
  end
  return nil
end

function ProjectReviewScreen:scroll_list_to_top()
  local component = self.list_view.scene:get('list')
  component:call(function()
    vim.fn.winrestview({ topline = 1 })
  end)
end

function ProjectReviewScreen:scroll_list_to_bottom()
  local component = self.list_view.scene:get('list')
  component:call(function()
    local line_count = vim.fn.line('$')
    local win_height = vim.fn.winheight(0)
    local topline = math.max(1, line_count - win_height + 1)
    vim.fn.winrestview({ topline = topline })
  end)
end

-- Handle navigation that involves commit expansion/collapse and folder expansion
-- direction: 'prev' (K key) or 'next' (J key)
-- Returns (item, wrapped) if handled, (nil, nil) if should fall back to standard navigation
function ProjectReviewScreen:navigate_commit_aware(direction)
  if self._navigating then return nil end
  if not self.list_view.get_entries then return nil end

  local entries = self.list_view:get_entries()
  if not entries then return nil end

  local all_files = self:build_logical_file_list(entries)
  if #all_files == 0 then return nil end

  -- Find current file index
  local current_item = self.list_view:get_current_list_item()
  if not current_item or not current_item.entry then return nil end

  local current_idx
  for i, info in ipairs(all_files) do
    if info.file.id == current_item.entry.id then
      current_idx = i
      break
    end
  end
  if not current_idx then return nil end

  -- Target index with wrap-around
  local delta = direction == 'prev' and -1 or 1
  local target_idx = ((current_idx - 1 + delta) % #all_files) + 1

  -- Detect wrap-around
  local wrapped = (direction == 'next' and target_idx < current_idx)
    or (direction == 'prev' and target_idx > current_idx)

  local target_info = all_files[target_idx]

  self._navigating = true

  -- Change active commit if needed (by-commit mode only)
  if self.list_view.get_active_commit then
    local active = self.list_view:get_active_commit()
    local active_hash = active and active.hash
    local active_section = active and active.section

    if target_info.commit_hash ~= active_hash or target_info.section ~= active_section then
      self.list_view:set_active_commit(target_info.commit_hash, target_info.section)
      self.list_view:render()
      self:update_commit_message()
    end
  end

  -- Navigate to the specific target file, expanding folders if needed
  local result = self:navigate_to_file_by_id(target_info.file.id, target_info.commit_hash)
  self._navigating = false
  return result, wrapped
end

-- Navigate to a specific file by ID, expanding parent folders if needed
function ProjectReviewScreen:navigate_to_file_by_id(file_id, commit_hash)
  local component = self.list_view.scene:get('list')

  local function find_and_move()
    local found_item, found_lnum
    self.list_view:each_list_item(function(item, lnum)
      if item.entry and item.entry.id == file_id then
        found_item, found_lnum = item, lnum
        return true
      end
    end)
    if found_item then
      loop.free_textlock()
      component:unlock():set_lnum(found_lnum):lock()
    end
    return found_item
  end

  -- Try visible items first, then expand folders and retry
  return find_and_move() or (self:expand_folders_for_file(file_id, commit_hash) and find_and_move())
end

-- Expand all parent folders for a file within a commit
function ProjectReviewScreen:expand_folders_for_file(file_id, commit_hash)
  local folds = self.list_view.state.folds
  if not folds then return false end

  -- Find the commit's items and the target file's path in one pass
  local commit_items, target_path
  for _, section in ipairs(folds) do
    for _, commit in ipairs(section.items or {}) do
      if commit.commit_hash == commit_hash then
        commit_items = commit.items or {}
        local function find_path(items)
          for _, item in ipairs(items) do
            if item.entry and item.entry.id == file_id then return item.entry.path end
            if item.items then
              local path = find_path(item.items)
              if path then return path end
            end
          end
        end
        target_path = find_path(commit_items)
        break
      end
    end
    if commit_items then break end
  end

  if not target_path then return false end

  -- Expand all folders that are parents of this file
  local function expand_parents(items)
    for _, item in ipairs(items) do
      if item.items and item.entry and item.entry.path then
        if vim.startswith(target_path, item.entry.path .. '/') then
          item.open = true
          expand_parents(item.items)
        end
      end
    end
  end
  expand_parents(commit_items)

  -- Re-sync folds
  local component = self.list_view.scene:get('list')
  component:unlock():set_title(self.list_view.state.title):set_list(folds):sync():lock()
  return true
end

-- Compare paths in path order (folders before files at each level, then alphabetically)
local function compare_paths(path_a, path_b)
  local parts_a = vim.split(path_a, '/')
  local parts_b = vim.split(path_b, '/')

  for i = 1, math.max(#parts_a, #parts_b) do
    local a = parts_a[i]
    local b = parts_b[i]

    if not a then return false end  -- a ended (file), b continues (folder) - folder first
    if not b then return true end   -- b ended (file), a continues (folder) - folder first

    local a_is_last = (i == #parts_a)
    local b_is_last = (i == #parts_b)

    if a_is_last ~= b_is_last then
      return not a_is_last  -- folder (not last) comes before file (last)
    end

    if a ~= b then
      return a < b
    end
  end

  return false
end

-- Build a flat list of all files in path order (folders before files, then alphabetically)
function ProjectReviewScreen:build_logical_file_list(entries)
  local files = {}
  for _, section in ipairs(entries) do
    -- Handle by-commit structure: section.commits
    if section.commits then
      for _, commit_data in ipairs(section.commits) do
        local sorted = {}
        for _, file in ipairs(commit_data.files or {}) do
          sorted[#sorted + 1] = file
        end
        table.sort(sorted, function(a, b)
          return compare_paths(a.status.filename, b.status.filename)
        end)

        for _, file in ipairs(sorted) do
          files[#files + 1] = {
            section = section.title,
            commit_hash = commit_data.commit.hash,
            file = file,
          }
        end
      end
    -- Handle by-file structure: section.entries
    elseif section.entries then
      local sorted = {}
      for _, file in ipairs(section.entries) do
        sorted[#sorted + 1] = file
      end
      table.sort(sorted, function(a, b)
        return compare_paths(a.status.filename, b.status.filename)
      end)

      for _, file in ipairs(sorted) do
        files[#files + 1] = {
          section = section.title,
          commit_hash = nil,
          file = file,
        }
      end
    end
  end
  return files
end

-- Find adjacent files in a section (for navigation after mark/unmark)
-- Returns next_file, prev_file, first_file as {filename, commit_hash} tables or nil
-- first_file: first file in section (for wrap-around when reaching end)
function ProjectReviewScreen:find_adjacent_files(target_section, current_filename, current_commit)
  if not self.list_view.get_entries then return nil, nil, nil end

  local entries = self.list_view:get_entries()
  if not entries then return nil, nil, nil end

  local all_files = self:build_logical_file_list(entries)
  local next_file, prev_file, first_file = nil, nil, nil
  local found_current = false
  local last_before_current = nil

  for _, info in ipairs(all_files) do
    if info.section == target_section then
      -- Track first file in section for wrap-around
      if not first_file then
        first_file = { filename = info.file.status.filename, commit_hash = info.commit_hash }
      end

      local is_current = info.file.status.filename == current_filename
        and (not current_commit or info.commit_hash == current_commit)

      if found_current and not next_file then
        next_file = { filename = info.file.status.filename, commit_hash = info.commit_hash }
        break
      end
      if is_current then
        found_current = true
        if last_before_current then
          prev_file = { filename = last_before_current.file.status.filename, commit_hash = last_before_current.commit_hash }
        end
      else
        last_before_current = info
      end
    end
  end

  return next_file, prev_file, first_file
end

-- Move cursor to first or last visible line in a commit
function ProjectReviewScreen:move_to_commit_line(commit_hash, section, position)
  local component = self.list_view.scene:get('list')
  local found_item, found_lnum = nil, nil

  self.list_view:each_list_item(function(item, lnum)
    if item.commit_hash == commit_hash and item.section_type == section then
      if position == 'first' and not found_item then
        found_item, found_lnum = item, lnum
      elseif position == 'last' then
        found_item, found_lnum = item, lnum
      end
    end
  end)

  if found_item then
    loop.free_textlock()
    component:unlock():set_lnum(found_lnum):lock()
  end
  return found_item
end

-- Move to an entry, expanding its commit if needed
-- commit_message: match by commit message (stable across rebases) instead of hash
function ProjectReviewScreen:move_to_entry_expanding_commit(filename, commit_hash, entry_type, commit_message)
  if not self.list_view.get_entries then return nil end

  local entries = self.list_view:get_entries()
  if not entries then return nil end

  -- Match commit by message (preferred, stable across rebases) or hash
  local function commit_matches(commit)
    if commit_message then
      return commit.message == commit_message
    end
    return not commit_hash or commit.hash == commit_hash
  end

  for _, section in ipairs(entries) do
    if not entry_type or section.title:lower() == entry_type then
      -- Handle by-commit structure: section.commits
      if section.commits then
        for _, commit_data in ipairs(section.commits) do
          if commit_matches(commit_data.commit) then
            for _, file in ipairs(commit_data.files or {}) do
              if file.status.filename == filename then
                -- Expand this commit and re-render
                if self.list_view:set_active_commit(commit_data.commit.hash, section.title) then
                  self.list_view:render()
                  self:update_commit_message()
                end
                -- Now find and move to the entry
                return self.list_view:move_to_entry(function(e)
                  return (not entry_type or e.type == entry_type)
                    and e.status.filename == filename
                    and e.commit_hash == commit_data.commit.hash
                end)
              end
            end
          end
        end
      -- Handle by-file structure: section.entries
      elseif section.entries then
        for _, file in ipairs(section.entries) do
          if file.status.filename == filename then
            return self.list_view:move_to_entry(function(e)
              return (not entry_type or e.type == entry_type)
                and e.status.filename == filename
            end)
          end
        end
      end
    end
  end
  return nil
end

-- Get the filtered mark index and count for navigation
function ProjectReviewScreen:get_filtered_mark_info()
  return self:get_mark_at_cursor()
end

function ProjectReviewScreen:next_hunk()
  local filtered_index, filtered_total = self:get_filtered_mark_info()
  local hunk_alignment = 'smart'

  if not filtered_index or filtered_total == 0 or filtered_index >= filtered_total then
    local list_item = self:move_to_next_file()
    if not list_item then return end
    self.model:set_entry_id(list_item.id)
    self.diff_view:render()
    self.diff_view:move_to_hunk(1, hunk_alignment)
  else
    self.diff_view:next(hunk_alignment)
  end
end

function ProjectReviewScreen:prev_hunk()
  local filtered_index, filtered_total = self:get_filtered_mark_info()
  local hunk_alignment = 'smart'

  if not filtered_index or filtered_total == 0 or filtered_index <= 1 then
    local list_item = self:move_to_prev_file()
    if not list_item then return end
    self.model:set_entry_id(list_item.id)
    self.diff_view:render()
    self.diff_view:move_to_hunk(0, hunk_alignment)
  else
    self.diff_view:prev(hunk_alignment)
  end
end

-- Position the list cursor on a specific file (by filename, optional commit_hash, and entry type)
function ProjectReviewScreen:move_list_cursor_to_file(filename, commit_hash, entry_type)
  -- For CommitListView, expand the correct commit first
  if self.list_view.get_entries then
    self:move_to_entry_expanding_commit(filename, commit_hash, entry_type)
    return
  end

  -- Fallback for non-commit views
  local component = self.list_view.scene:get('list')
  self.list_view:find_list_item(function(item, lnum)
    if not item.entry or not item.entry.status then return false end
    if item.entry.status.filename ~= filename then return false end
    if commit_hash and item.entry.commit_hash ~= commit_hash then return false end
    if entry_type and item.entry.type ~= entry_type then return false end
    loop.free_textlock()
    component:unlock():set_lnum(lnum):lock()
    return true
  end)
end

-- Convert original hunk index to filtered display index
function ProjectReviewScreen:get_filtered_hunk_index(original_index)
  local diff = self.model:get_diff()
  if not diff or not diff.original_indices then return original_index end

  for filtered_idx, orig_idx in ipairs(diff.original_indices) do
    if orig_idx == original_index then
      return filtered_idx
    end
  end

  return 1 -- Fallback to first hunk
end

-- Find a matching hunk in the given range
local function find_hunk_in_range(model, content_ids, mark_key, target_seen_state, start, stop, step)
  for i = start, stop, step or 1 do
    local content_id = content_ids[i]
    if content_id and model:is_hunk_seen(mark_key, content_id) == target_seen_state then
      return i
    end
  end
  return nil
end

-- Find next hunk matching target_seen_state starting from a specific file/hunk
-- target_seen_state: true = find seen hunks (for auto-advance after unmarking)
--                    false = find unseen hunks (for auto-advance after marking)
-- next_file/prev_file/first_file: optional {filename, commit_hash} found BEFORE rebuild
--
-- Navigation order (section is a cohesive loop):
--   1. Hunks after current in same file
--   2. Next file in section (first hunk)
--   3. Wrap to first file in section (catches skipped files at start)
--   4. Hunks before current in same file (catches skipped hunks in current file)
--   5. Section complete - stay on current file (now in opposite section)
function ProjectReviewScreen:move_to_hunk_matching(target_seen_state, mark_key, filename, commit_hash, from_hunk, total_hunks, next_file, prev_file, first_file)
  local hunk_alignment = 'smart'
  local target_entry_type = target_seen_state and 'seen' or 'unseen'

  -- Get content_ids for current file
  local entry = self.model:get_entry()
  local content_ids = entry and self.model:get_content_ids(entry) or {}

  -- 1. Check hunks after current in same file
  local match_idx = find_hunk_in_range(self.model, content_ids, mark_key, target_seen_state, from_hunk + 1, total_hunks)
  if match_idx then
    local found_entry = self:move_to_entry_expanding_commit(filename, commit_hash, target_entry_type)
    if found_entry then
      self.model:set_entry_id(found_entry.id)
      loop.free_textlock()
      self.diff_view:save_viewport()  -- Preserve viewport for same-file navigation
      self.diff_view:render()
      loop.free_textlock()
      self.diff_view:move_to_hunk(self:get_filtered_hunk_index(match_idx), hunk_alignment)
    end
    return
  end

  -- 2. Try next file in section (first hunk)
  if next_file then
    local found_entry = self:move_to_entry_expanding_commit(
      next_file.filename, next_file.commit_hash, target_entry_type)
    if found_entry then
      self.model:set_entry_id(found_entry.id)
      loop.free_textlock()
      self.diff_view:render()
      self.diff_view:move_to_hunk(1, hunk_alignment)
      return
    end
  end

  -- 3. Wrap to first file in section (catches skipped files at start)
  if first_file then
    local found_entry = self:move_to_entry_expanding_commit(
      first_file.filename, first_file.commit_hash, target_entry_type)
    if found_entry then
      self.model:set_entry_id(found_entry.id)
      loop.free_textlock()
      self.diff_view:render()
      self.diff_view:move_to_hunk(1, hunk_alignment)
      return
    end
  end

  -- 4. Check hunks before current in same file (catches skipped hunks)
  match_idx = find_hunk_in_range(self.model, content_ids, mark_key, target_seen_state, from_hunk - 1, 1, -1)
  if match_idx then
    local found_entry = self:move_to_entry_expanding_commit(filename, commit_hash, target_entry_type)
    if found_entry then
      self.model:set_entry_id(found_entry.id)
      loop.free_textlock()
      self.diff_view:save_viewport()  -- Preserve viewport for same-file navigation
      self.diff_view:render()
      loop.free_textlock()
      self.diff_view:move_to_hunk(self:get_filtered_hunk_index(match_idx), hunk_alignment)
    end
    return
  end

  -- 5. Section complete - stay on current file (now in opposite section)
  local opposite_type = target_seen_state and 'unseen' or 'seen'
  local current_entry = self:move_to_entry_expanding_commit(filename, commit_hash, opposite_type)
  if current_entry then
    self.model:set_entry_id(current_entry.id)
  end

  loop.free_textlock()
  self.diff_view:render()
  self.diff_view:move_to_hunk(1, hunk_alignment)
end

function ProjectReviewScreen:mark_hunk()
  -- Prevent concurrent mark operations
  if self._marking then return end
  self._marking = true

  local entry = self.model:get_entry()
  if not entry then
    self._marking = false
    return
  end

  local ctx = self:get_entry_context(entry)
  local hunk_index, total_hunks = self:get_current_mark_index()
  if not hunk_index then
    self._marking = false
    return
  end

  -- Get content_id for this hunk
  local content_ids = self.model:get_content_ids(entry)
  local content_id = content_ids[hunk_index]
  if not content_id then
    self._marking = false
    return
  end

  -- Save context before marking (entry may be removed after render if file becomes fully seen)
  local current_mark_key = ctx.mark_key
  local current_filename = ctx.filename
  local current_commit = ctx.commit_hash
  local current_hunk = hunk_index

  -- Find adjacent unseen files BEFORE rebuilding (includes files in collapsed commits)
  local next_file, prev_file, first_file = self:find_adjacent_files('Unseen', current_filename, current_commit)

  self.model:mark_hunk(ctx.mark_key, content_id)
  self.list_view:render()

  -- Navigate to next unmarked hunk using saved context
  self:move_to_hunk_matching(false, current_mark_key, current_filename, current_commit, current_hunk, total_hunks, next_file, prev_file, first_file)
  self._marking = false
end

function ProjectReviewScreen:unmark_hunk()
  -- Prevent concurrent mark operations
  if self._marking then return end
  self._marking = true

  local entry = self.model:get_entry()
  if not entry then
    self._marking = false
    return
  end

  local ctx = self:get_entry_context(entry)
  local hunk_index, total_hunks = self:get_current_mark_index()
  if not hunk_index then
    self._marking = false
    return
  end

  -- Get content_id for this hunk
  local content_ids = self.model:get_content_ids(entry)
  local content_id = content_ids[hunk_index]
  if not content_id then
    self._marking = false
    return
  end

  -- Save context before unmarking (entry may be removed after render if file becomes fully unseen)
  local current_mark_key = ctx.mark_key
  local current_filename = ctx.filename
  local current_commit = ctx.commit_hash
  local current_hunk = hunk_index

  -- Find adjacent seen files BEFORE rebuilding (includes files in collapsed commits)
  local next_file, prev_file, first_file = self:find_adjacent_files('Seen', current_filename, current_commit)

  self.model:unmark_hunk(ctx.mark_key, content_id)

  -- Clear active commit before render (it may no longer exist)
  if self.list_view.set_active_commit then
    self.list_view:set_active_commit(nil)
  end
  self.list_view:render()

  -- Navigate to next marked hunk using saved context
  self:move_to_hunk_matching(true, current_mark_key, current_filename, current_commit, current_hunk, total_hunks, next_file, prev_file, first_file)
  self._marking = false
end

-- Unified mark/unmark file operation
-- mark_as_seen: true = mark all hunks as seen, false = unmark all hunks
function ProjectReviewScreen:set_file_seen_state(mark_as_seen)
  -- Prevent concurrent mark operations
  if self._marking then return end
  self._marking = true

  local entry = self.model:get_entry()
  if not entry then
    self._marking = false
    return
  end

  local ctx = self:get_entry_context(entry)
  local current_filename = ctx.filename
  local current_commit = ctx.commit_hash
  local current_type = entry.type

  -- The entry type we stay on if we were already viewing that state
  local same_state_type = mark_as_seen and 'seen' or 'unseen'
  -- The entry type we find next if we were viewing opposite state
  local opposite_state_type = mark_as_seen and 'unseen' or 'seen'

  -- Save the original hunk index before operation (for cursor preservation)
  local saved_hunk_index, _ = self:get_current_mark_index()
  local hunk_alignment = 'smart'

  -- Find adjacent files in the opposite-state section BEFORE rebuilding
  local next_file, prev_file = nil, nil
  if current_type == opposite_state_type then
    local target_section = opposite_state_type == 'seen' and 'Seen' or 'Unseen'
    next_file, prev_file = self:find_adjacent_files(target_section, current_filename, current_commit)
  end

  -- Perform the mark/unmark using mark_key (filename only)
  if mark_as_seen then
    self.model:mark_file(ctx.mark_key)
  else
    self.model:unmark_file(ctx.mark_key)
    -- Clear active commit before render (it may no longer exist)
    if self.list_view.set_active_commit then
      self.list_view:set_active_commit(nil)
    end
  end
  self.list_view:render()

  -- If we were on the same state entry (seen for mark, unseen for unmark), stay on same file and hunk
  if current_type == same_state_type then
    local found_entry = self.list_view:move_to_entry(function(e)
      if e.type ~= same_state_type then return false end
      if not e.status or e.status.filename ~= current_filename then return false end
      if current_commit and e.commit_hash ~= current_commit then return false end
      return true
    end)
    if found_entry then
      self.model:set_entry_id(found_entry.id)
      self.diff_view:render()
      -- After operation, all hunks are in same state, so original index = filtered index
      self.diff_view:move_to_hunk(saved_hunk_index, hunk_alignment)
    end
    self._marking = false
    return
  end

  -- Navigate to next opposite-state file, or prev if on last, or stay if none left
  local found_entry
  if next_file then
    found_entry = self:move_to_entry_expanding_commit(next_file.filename, next_file.commit_hash, opposite_state_type)
  elseif prev_file then
    found_entry = self:move_to_entry_expanding_commit(prev_file.filename, prev_file.commit_hash, opposite_state_type)
  end

  -- If no opposite-state entries found, stay on the current file (now in same_state section)
  if not found_entry then
    found_entry = self:move_to_entry_expanding_commit(current_filename, current_commit, same_state_type)
  end

  if found_entry and found_entry.id then
    self.model:set_entry_id(found_entry.id)
    self.diff_view:render()
    self.diff_view:move_to_hunk(nil, hunk_alignment)
  end
  self._marking = false
end

function ProjectReviewScreen:mark_file()
  self:set_file_seen_state(true)
end

function ProjectReviewScreen:unmark_file()
  self:set_file_seen_state(false)
end

function ProjectReviewScreen:reset_marks()
  -- Prevent concurrent mark operations
  if self._marking then return end

  loop.free_textlock()
  local decision = console.input('Reset all marks? (y/N) '):lower()
  if decision ~= 'yes' and decision ~= 'y' then return end

  self._marking = true
  loop.free_textlock()
  self.model:reset_marks()
  self.list_view:render()
  self._marking = false
end

function ProjectReviewScreen:toggle_focus()
  local list_component = self.scene:get('list')
  local diff_component = self.scene:get('current')

  if list_component:is_focused() then
    local hunk_alignment = 'smart'
    diff_component:focus()
    self.diff_view:move_to_hunk(1, hunk_alignment)
    self._current_focus = 'diff'
  else
    list_component:focus()
    self._current_focus = 'list'
  end
end

function ProjectReviewScreen:handle_list_move()
  -- Skip if we're in the middle of a mark operation
  if self._marking then return end

  -- Check if this was keyboard navigation (flag set by keymap handlers)
  local keyboard_direction = self._keyboard_nav_direction
  self._keyboard_nav_direction = nil

  local list_item = self.list_view:move()
  if not list_item then return end

  -- Handle commit expansion (only for CommitListView)
  -- keyboard_direction is nil for mouse clicks, so "move to last line" won't trigger
  list_item = self:update_commit_expansion(list_item, keyboard_direction) or list_item

  local hunk_alignment = 'smart'
  self.model:set_entry_id(list_item.id)
  self.diff_view:render()
  self.diff_view:move_to_hunk(nil, hunk_alignment)
end

-- Update which commit is expanded based on cursor position
-- Returns the new list_item if cursor was moved, nil otherwise
function ProjectReviewScreen:update_commit_expansion(list_item, direction)
  if self._navigating then return nil end
  if not self.list_view.set_active_commit then return nil end

  local target_hash = list_item.commit_hash
  local target_section = list_item.section_type

  -- Skip if on section header (no commit to expand)
  if not target_hash then return nil end

  if self.list_view:set_active_commit(target_hash, target_section) then
    self._navigating = true
    self:rerender_list_preserving_cursor(list_item)
    self:update_commit_message()

    -- If on a commit header after expansion and going UP, move to last line
    -- (For DOWN, stay on header so next down goes to first line naturally)
    local is_commit_header = not list_item.node_type and list_item.commit_hash
    if is_commit_header and direction == 'up' then
      local new_item = self:move_to_commit_line(target_hash, list_item.section_type, 'last')
      self._navigating = false
      return new_item
    end

    self._navigating = false
  end
  return nil
end

-- Re-render list while preserving cursor on the same item
function ProjectReviewScreen:rerender_list_preserving_cursor(target_item)
  local component = self.list_view.scene:get('list')
  local target_entry_id = target_item.entry and target_item.entry.id

  self.list_view:render()

  self.list_view:find_list_item(function(item, lnum)
    local matched
    if target_entry_id then
      matched = item.entry and item.entry.id == target_entry_id
    else
      matched = item.commit_hash == target_item.commit_hash
        and item.section_type == target_item.section_type
        and item.value == target_item.value
    end

    if matched then
      loop.free_textlock()
      component:unlock():set_lnum(lnum):lock()
    end
    return matched
  end)
end

-- Ensure at least one file is visible (expand first commit if needed)
-- Prefers Unseen commits to bias towards action
function ProjectReviewScreen:ensure_visible_file()
  if not self.list_view.get_entries then return end

  -- Check if any file is currently visible
  local has_visible_file = false
  self.list_view:each_list_item(function(item)
    if item.node_type == 'file' then
      has_visible_file = true
      return true
    end
  end)

  if has_visible_file then return end

  -- No visible files - expand first Unseen commit, or first Seen if none
  local entries = self.list_view:get_entries()
  if not entries then return end

  local fallback_section, fallback_commit = nil, nil
  for _, section in ipairs(entries) do
    if section.commits and #section.commits > 0 then
      if section.title == 'Unseen' then
        local first_commit = section.commits[1].commit
        self.list_view:set_active_commit(first_commit.hash, section.title)
        self.list_view:render()
        self:update_commit_message()
        return
      elseif not fallback_commit then
        fallback_section = section
        fallback_commit = section.commits[1].commit
      end
    end
  end

  -- No Unseen commits, use fallback
  if fallback_commit then
    self.list_view:set_active_commit(fallback_commit.hash, fallback_section.title)
    self.list_view:render()
    self:update_commit_message()
  end
end

function ProjectReviewScreen:open_file()
  local filepath = self.model:get_filepath()
  if not filepath then return end

  -- Handle deleted files: move to next file
  if not fs.exists(filepath) then
    local list_item = self:move_to_next_file()
    if not list_item then
      console.info('File has been deleted')
      return
    end
    self.model:set_entry_id(list_item.id)
    filepath = self.model:get_filepath()
    if not filepath or not fs.exists(filepath) then
      console.info('File has been deleted')
      return
    end
    self.diff_view:render()
  end

  local mark = self.diff_view:get_current_mark_under_cursor()

  loop.free_textlock()
  self:destroy()
  fs.open(filepath)

  if not mark then
    local diff, diff_err = self.model:get_diff()
    if diff_err or not diff then return end
    mark = diff.marks[1]
    if not mark then return end
  end

  Window(0):set_lnum(mark.top_relative):position_cursor('center')
  event.emit('VGitSync')
end

function ProjectReviewScreen:render(on_list_render)
  self.list_view:render()
  if on_list_render then on_list_render() end

  local list_item = self.list_view:get_current_list_item()
  if list_item then
    self.model:set_entry_id(list_item.id)
  end

  local hunk_alignment = 'smart'
  self.diff_view:render()
  self.diff_view:move_to_hunk(nil, hunk_alignment)
end

function ProjectReviewScreen:setup_list_keymaps()
  local keymaps = self.setting:get('keymaps')

  -- Navigation key handlers that set direction flag before native movement
  -- This allows us to distinguish keyboard nav from mouse clicks
  local nav_keys = {
    { key = 'k', direction = 'up' },
    { key = '<Up>', direction = 'up' },
    { key = 'j', direction = 'down' },
    { key = '<Down>', direction = 'down' },
  }
  for _, nav in ipairs(nav_keys) do
    self.list_view:set_keymap({
      {
        mode = 'n',
        key = nav.key,
        handler = function()
          self._keyboard_nav_direction = nav.direction
          -- Execute native movement (will trigger CursorMoved -> handle_list_move)
          vim.cmd('normal! ' .. vim.api.nvim_replace_termcodes(nav.key, true, false, true))
        end,
      },
    })
  end

  self.list_view:set_keymap({
    {
      mode = 'n',
      mapping = keymaps.toggle_focus,
      handler = function()
        self:toggle_focus()
      end,
    },
    {
      mode = 'n',
      mapping = keymaps.mark_hunk,
      handler = loop.debounce_coroutine(function()
        self:mark_hunk()
      end, 15),
    },
    {
      mode = 'n',
      mapping = keymaps.unmark_hunk,
      handler = loop.debounce_coroutine(function()
        self:unmark_hunk()
      end, 15),
    },
    {
      mode = 'n',
      mapping = keymaps.mark_file,
      handler = loop.debounce_coroutine(function()
        self:mark_file()
      end, 15),
    },
    {
      mode = 'n',
      mapping = keymaps.unmark_file,
      handler = loop.debounce_coroutine(function()
        self:unmark_file()
      end, 15),
    },
    {
      mode = 'n',
      mapping = keymaps.reset,
      handler = loop.coroutine(function()
        self:reset_marks()
      end),
    },
    {
      mode = 'n',
      mapping = keymaps.next,
      handler = loop.debounce_coroutine(function()
        local list_item = self:move_to_next_file()
        if not list_item then return end
        self.model:set_entry_id(list_item.id)
        local hunk_alignment = 'smart'
        self.diff_view:render()
        self.diff_view:move_to_hunk(1, hunk_alignment)
      end, 15),
    },
    {
      mode = 'n',
      mapping = keymaps.previous,
      handler = loop.debounce_coroutine(function()
        local list_item = self:move_to_prev_file()
        if not list_item then return end
        self.model:set_entry_id(list_item.id)
        local hunk_alignment = 'smart'
        self.diff_view:render()
        self.diff_view:move_to_hunk(0, hunk_alignment)
      end, 15),
    },
  })
end

function ProjectReviewScreen:setup_diff_keymaps()
  local keymaps = self.setting:get('keymaps')

  local handlers = {
    mark_hunk = loop.debounce_coroutine(function()
      self:mark_hunk()
    end, 15),
    unmark_hunk = loop.debounce_coroutine(function()
      self:unmark_hunk()
    end, 15),
    mark_file = loop.debounce_coroutine(function()
      self:mark_file()
    end, 15),
    unmark_file = loop.debounce_coroutine(function()
      self:unmark_file()
    end, 15),
    reset = loop.coroutine(function()
      self:reset_marks()
    end),
    next_hunk = loop.debounce_coroutine(function()
      self:next_hunk()
    end, 15),
    prev_hunk = loop.debounce_coroutine(function()
      self:prev_hunk()
    end, 15),
    enter = loop.coroutine(function()
      self:open_file()
    end),
  }

  self.diff_keymaps = handlers

  self.diff_view:set_keymap({
    {
      mode = 'n',
      mapping = keymaps.mark_hunk,
      handler = handlers.mark_hunk,
    },
    {
      mode = 'n',
      mapping = keymaps.unmark_hunk,
      handler = handlers.unmark_hunk,
    },
    {
      mode = 'n',
      mapping = keymaps.mark_file,
      handler = handlers.mark_file,
    },
    {
      mode = 'n',
      mapping = keymaps.unmark_file,
      handler = handlers.unmark_file,
    },
    {
      mode = 'n',
      mapping = keymaps.reset,
      handler = handlers.reset,
    },
    {
      mode = 'n',
      mapping = keymaps.toggle_focus,
      handler = function()
        self:toggle_focus()
      end,
    },
    {
      mode = 'n',
      mapping = keymaps.next,
      handler = handlers.next_hunk,
    },
    {
      mode = 'n',
      mapping = keymaps.previous,
      handler = handlers.prev_hunk,
    },
    {
      mode = 'n',
      mapping = {
        key = '<enter>',
        desc = 'Open buffer',
      },
      handler = handlers.enter,
    },
  })
end

function ProjectReviewScreen:setup_keymaps()
  self:setup_list_keymaps()
  self:setup_diff_keymaps()
end

-- Returns true if current buffer is in the review (triggers source line positioning)
function ProjectReviewScreen:focus_relative_buffer_entry(buffer)
  local review_state = self.model:get_review_state()
  local last_section, last_filename, last_commit_message = review_state:get_position()

  -- Priority 1: Find current buffer's file, preferring saved section
  -- This keeps the review in sync with what you're editing in vim
  local filename = buffer:get_relative_name()
  if filename ~= '' then
    if self.list_view.get_entries then
      local found = self:move_to_entry_expanding_commit(filename, nil, last_section, last_commit_message)
        or self:move_to_entry_expanding_commit(filename, nil, last_section)
        or self:move_to_entry_expanding_commit(filename, nil, nil)
      if found then return true end
    else
      local list_item = self:move_to(function(status, entry_type)
        return status.filename == filename and entry_type == last_section
      end) or self:move_to(function(status)
        return status.filename == filename
      end)
      if list_item then return true end
    end
  end

  -- Priority 2: Current buffer not in review - restore saved position
  if last_filename then
    if self.list_view.get_entries then
      local found = self:move_to_entry_expanding_commit(last_filename, nil, last_section, last_commit_message)
        or self:move_to_entry_expanding_commit(last_filename, nil, last_section)
        or self:move_to_entry_expanding_commit(last_filename, nil, nil)
      if found then return false end
    else
      local list_item = self:move_to(function(status, entry_type)
        return status.filename == last_filename and entry_type == last_section
      end) or self:move_to(function(status)
        return status.filename == last_filename
      end)
      if list_item then return false end
    end
  end

  -- Fallback: prefer unseen entries
  if not self:move_to(function(_, entry_type) return entry_type == 'unseen' end) then
    self:move_to(function() return true end)
  end
  return false
end

function ProjectReviewScreen:create(args)
  args = args or {}
  local base_branch = args[1]
  local buffer = Buffer(0)
  -- Capture cursor position and window BEFORE mounting any views
  local source_cursor_lnum = vim.fn.line('.')
  local source_cursor_col = vim.fn.col('.')
  local source_winline = vim.fn.winline()
  local source_win_id = vim.api.nvim_get_current_win()

  loop.free_textlock()
  local data, err = self.model:fetch(base_branch)
  loop.free_textlock()

  if err then
    console.debug.error(err).error(err)
    return false
  end

  if utils.object.is_empty(data) then
    console.info('No changes to review')
    return false
  end

  self.app_bar_view:define()
  self.diff_view:define()
  self.list_view:define()
  if self.commit_message_view then
    self.commit_message_view:define()
  end

  self.diff_view:mount()
  self.app_bar_view:mount()
  self.list_view:mount({
    event_handlers = {
      on_enter = function()
        self:open_file()
      end,
      on_move = function()
        self:handle_list_move()
      end,
    },
  })
  if self.commit_message_view then
    self.commit_message_view:mount()
  end

  self.diff_view:render()
  self.app_bar_view:render()
  self.list_view:render()
  if self.commit_message_view then
    self.commit_message_view:render()
  end

  self:setup_keymaps()
  self:ensure_visible_file()
  local found_current_buffer = self:focus_relative_buffer_entry(buffer)
  self:handle_list_move()

  -- Set focus explicitly based on saved state (default to diff for bias towards action)
  -- Don't use toggle_focus() here since commit_message_view may have stolen focus during mount
  local review_state = self.model:get_review_state()
  local _, _, _, saved_focus = review_state:get_position()
  if saved_focus == 'list' then
    self.scene:get('list'):focus()
    self._current_focus = 'list'
  else
    local hunk_alignment = 'smart'
    self.scene:get('current'):focus()
    self.diff_view:move_to_hunk(1, hunk_alignment)
    self._current_focus = 'diff'
  end

  -- Position cursor at source file line (must be after focus logic which resets to first hunk)
  if found_current_buffer then
    vim.schedule(function()
      self.diff_view:set_source_lnum(source_cursor_lnum, source_cursor_col, source_winline)
    end)
  end

  -- Store source window for returning on quit
  self.source_win_id = source_win_id

  return true
end

function ProjectReviewScreen:on_quit()
  local focus = self._current_focus or 'diff'
  local is_diff_focused = focus == 'diff'

  -- Always save state, regardless of which component is focused
  local entry = self.model:get_entry()
  local review_state = self.model:get_review_state()
  if review_state and entry then
    local commit_message = entry.commit and entry.commit.message or nil
    review_state:save_position(entry.type, entry.filename, commit_message, focus)
  end
  if review_state then
    review_state:save()
  end

  local filepath = self.model:get_filepath()

  -- Get cursor position info only if focused on diff
  local file_lnum, diff_winline
  if is_diff_focused then
    file_lnum = self.diff_view:get_file_lnum()
    diff_winline = vim.fn.winline()
  end

  -- Handle deleted files: just close the screen
  if not filepath or not fs.exists(filepath) then
    loop.free_textlock()
    self:destroy()
    return true
  end

  loop.free_textlock()
  local source_win_id = self.source_win_id
  self:destroy()

  -- Return to the original window if it still exists
  if source_win_id and vim.api.nvim_win_is_valid(source_win_id) then
    vim.api.nvim_set_current_win(source_win_id)
  end

  fs.open(filepath)

  -- Restore cursor position if we were in the diff view
  if file_lnum then
    Window(0):set_lnum(file_lnum)
    local target_top = file_lnum - diff_winline + 1
    if target_top >= 1 then
      vim.fn.winrestview({ topline = target_top })
    end
  end

  event.emit('VGitSync')
  return true
end

function ProjectReviewScreen:destroy()
  -- Save review state before destroying (handles :q, window close, etc.)
  -- Use pcall since destroy may be called from various contexts
  local current_focus = self._current_focus
  pcall(function()
    local entry = self.model:get_entry()
    local review_state = self.model:get_review_state()
    if review_state and entry then
      local focus = current_focus or 'diff'
      local commit_message = entry.commit and entry.commit.message or nil
      review_state:save_position(entry.type, entry.filename, commit_message, focus)
    end
    if review_state then
      review_state:save()
    end
  end)

  loop.close_debounced_handlers(self.diff_keymaps)
  self.diff_keymaps = {}
  self.scene:destroy()
end

return ProjectReviewScreen
