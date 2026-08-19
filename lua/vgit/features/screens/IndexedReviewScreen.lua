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
local dimensions = require('vgit.ui.dimensions')
local drag_resize = require('vgit.ui.drag_resize')
local KeyHelpBarView = require('vgit.ui.views.KeyHelpBarView')
local section_headings = require('vgit.ui.views.StatusListView.section_headings')
local file_navigation = require('vgit.features.screens.file_navigation')
local visual_selection = require('vgit.features.screens.visual_selection')

--[[
  IndexedReviewScreen is the base class for the indexed review screens
  (IndexedFileReviewScreen and IndexedCommitReviewScreen). It is a fork of
  ProjectReviewScreen adapted to the index model: marks are edits to an
  approved content snapshot rather than per-hunk flags, so hunk indices in a
  section shift as hunks are marked, and s/u also work on visual selections
  (line-level marking, current pane only in split layout).

  Subclasses must:
    - Set self.list_view in constructor
    - Set self.setting in constructor
]]

local IndexedReviewScreen = Object:extend()

function IndexedReviewScreen:constructor(opts)
  opts = opts or {}
  local scene = Scene()

  return {
    name = 'Indexed Review Screen',
    scene = scene,
    model = nil,      -- Set by subclass
    setting = nil,    -- Set by subclass
    list_view = nil,  -- Set by subclass
    list_cols = nil,  -- Set by subclass when the list/diff boundary is draggable
    diff_keymaps = {},
    app_bar_view = nil,
    diff_view = nil,
    _marking = false,     -- Lock to prevent concurrent mark operations
    _navigating = false,  -- Lock to prevent concurrent commit navigation
  }
end

-- Update commit message view if present (scheduled to escape fast event context)
function IndexedReviewScreen:update_commit_message()
  if not self.commit_message_view then return end
  local view = self.commit_message_view
  vim.schedule(function() view:render() end)
end

-- Initialize views (called by subclass after setting model and setting)
function IndexedReviewScreen:init_views(list_plot, diff_plot)
  local model = self.model
  local setting = self.setting

  self.app_bar_view = KeyHelpBarView(self.scene, {
    keymaps = function()
      local keymaps = setting:get('keymaps')
      return {
        { 'Mark hunk/lines',   keymaps['mark_hunk'] },
        { 'Mark file',         keymaps['mark_file'] },
        { 'Unmark hunk/lines', keymaps['unmark_hunk'] },
        { 'Unmark file',       keymaps['unmark_file'] },
        { 'Reset',             keymaps['reset'] },
        { 'Next',              keymaps['next'] },
        { 'Previous',          keymaps['previous'] },
        { 'Jump section',      keymaps['jump_section_next'] },
      }
    end,
  })

  self.diff_view = DiffView(self.scene, {
    layout_type = function()
      return model:get_layout_type()
    end,
    filepath = function()
      return model:get_filepath()
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

function IndexedReviewScreen:move_to(query_fn)
  return self.list_view:move_to(query_fn)
end

function IndexedReviewScreen:get_mark_at_cursor()
  return self.diff_view:get_cursor_mark_position()
end

-- Returns (hunk_index, total_hunks) for the cursor position in the current
-- entry's diff. Indexed diffs are never filtered, so the cursor index maps
-- straight onto diff.hunks. Returns (nil, 0) on hunkless diffs (identical
-- content, e.g. a marked pure rename) - callers fall back to file-level ops.
function IndexedReviewScreen:get_current_mark_index()
  loop.free_textlock()
  local diff = self.model:get_diff()
  if not diff or not diff.marks or #diff.marks == 0 then return nil, 0 end

  local index = self:get_mark_at_cursor()
  if not index then return nil, 0 end

  return index, #diff.marks
end

function IndexedReviewScreen:move_to_next_file()
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

function IndexedReviewScreen:move_to_prev_file()
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

-- Point the diff pane at list_item and align to its first (next) / last (prev) hunk.
function IndexedReviewScreen:focus_list_item_in_diff(list_item, direction)
  self.model:set_entry_id(list_item.id)
  self.diff_view:render()
  self.diff_view:move_to_hunk(direction == 'next' and 1 or 0, 'smart')
end

-- Move the list cursor to the adjacent file (wraps) and align the diff to its
-- first hunk (next) or last hunk (prev).
function IndexedReviewScreen:move_to_adjacent_file(direction)
  local list_item = direction == 'next' and self:move_to_next_file() or self:move_to_prev_file()
  if list_item then self:focus_list_item_in_diff(list_item, direction) end
end

-- J/K in the diff pane: jump to the last (next) / first (prev) hunk in the
-- current file. If already at that edge, cross into the next / previous file's
-- first / last hunk.
function IndexedReviewScreen:jump_to_file_edge(direction)
  -- Skip if we're in the middle of a mark operation
  if self._marking then return end

  local current_index, total_hunks, position = self:get_mark_at_cursor()
  if file_navigation.should_cross_file(direction, current_index, total_hunks, position) then
    return self:move_to_adjacent_file(direction)
  end

  -- Not at the edge yet: jump to this file's last (next, 0) / first (prev, 1) hunk.
  self.diff_view:move_to_hunk(direction == 'next' and 0 or 1, 'smart')
end

function IndexedReviewScreen:scroll_list_to_top()
  local component = self.list_view.scene:get('list')
  component:call(function()
    vim.fn.winrestview({ topline = 1 })
  end)
end

function IndexedReviewScreen:scroll_list_to_bottom()
  local component = self.list_view.scene:get('list')
  component:call(function()
    local line_count = vim.fn.line('$')
    local win_height = vim.fn.winheight(0)
    local topline = math.max(1, line_count - win_height + 1)
    vim.fn.winrestview({ topline = topline })
  end)
end

-- Find first file id in a node's items subtree (depth-first, matching visual order)
local function first_file_id_in_tree(items)
  for _, item in ipairs(items or {}) do
    if item.node_type == 'file' and item.id then return item.id end
    if item.items then
      local id = first_file_id_in_tree(item.items)
      if id then return id end
    end
  end
end

-- Find current file index in all_files list. Returns on_header=true when the
-- cursor is on a header (folder, commit, or section) rather than a file —
-- callers use that to land on the first file under the header (rather than
-- +1 past it) when going next.
function IndexedReviewScreen:get_current_file_index(all_files)
  local current_item = self.list_view:get_current_list_item()
  if not current_item then return nil end

  -- Resolve the cursor to a file id: the file itself, or the first descendant
  -- if on a folder. Folder entries carry a spurious `entry.id` from
  -- normalization (last file processed wins), so we MUST descend the subtree
  -- rather than trust that id.
  local file_id
  if current_item.node_type == 'file' then
    file_id = current_item.id
  elseif current_item.node_type == 'folder' then
    file_id = first_file_id_in_tree(current_item.items)
  end
  if file_id then
    for i, info in ipairs(all_files) do
      if info.file.id == file_id then
        return i, current_item.node_type ~= 'file'
      end
    end
  end

  -- On a commit header: return first file of that commit
  if current_item.commit_hash and not current_item.node_type then
    for i, info in ipairs(all_files) do
      if info.commit_hash == current_item.commit_hash and info.section == current_item.section_type then
        return i, true
      end
    end
  end

  -- On a section header: return first file of the active commit
  if self.list_view.get_active_commit then
    local active = self.list_view:get_active_commit()
    if active and active.hash then
      for i, info in ipairs(all_files) do
        if info.commit_hash == active.hash and info.section == active.section then
          return i, true
        end
      end
    end
  end

  return #all_files > 0 and 1 or nil, true
end

-- Handle navigation that involves commit expansion/collapse and folder expansion
-- direction: 'prev' or 'next'
-- Returns (item, wrapped) if handled, (nil, nil) if should fall back to standard navigation
function IndexedReviewScreen:navigate_commit_aware(direction)
  if self._navigating then return nil end
  if not self.list_view.get_entries then return nil end

  local entries = self.list_view:get_entries()
  if not entries then return nil end

  local all_files = file_navigation.build_logical_file_list(entries)
  if #all_files == 0 then return nil end

  local current_idx, on_header = self:get_current_file_index(all_files)
  if not current_idx then return nil end

  -- When on a header, current_idx is the first file under the header:
  --   'next' lands there directly (skipping the +1 step would skip that file),
  --   'prev' steps -1 to the previous header's last file, which is correct.
  local target_idx
  if on_header and direction == 'next' then
    target_idx = current_idx
  else
    local delta = direction == 'prev' and -1 or 1
    target_idx = ((current_idx - 1 + delta) % #all_files) + 1
  end

  -- Detect wrap-around
  local wrapped = (direction == 'next' and target_idx < current_idx)
    or (direction == 'prev' and target_idx > current_idx)

  local result = self:goto_logical_file(all_files[target_idx])
  return result, wrapped
end

-- Switch to the commit owning target_info (if needed), expand its folders, and
-- move the list cursor onto that file. Returns the list_item, or nil.
function IndexedReviewScreen:goto_logical_file(target_info)
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
  return result
end

-- Navigate to a specific file by ID, expanding parent folders if needed
function IndexedReviewScreen:navigate_to_file_by_id(file_id, commit_hash)
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
function IndexedReviewScreen:expand_folders_for_file(file_id, commit_hash)
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

-- Find adjacent files in a section (for navigation after mark/unmark).
-- Returns next_file, prev_file, first_file as {filepath, commit_hash} tables or nil.
-- first_file is used for wrap-around when reaching end of section.
function IndexedReviewScreen:find_adjacent_files(target_section, current_filepath, current_commit)
  if not self.list_view.get_entries then return nil, nil, nil end

  local entries = self.list_view:get_entries()
  if not entries then return nil, nil, nil end

  local all_files = file_navigation.build_logical_file_list(entries)
  return file_navigation.find_adjacent_files(all_files, current_filepath, current_commit, function(info)
    return info.section == target_section
  end)
end

-- J/K in the list pane. By-commit jumps to the adjacent commit; by-file jumps
-- between crate-level folder headings (see
-- vgit.ui.views.StatusListView.section_headings for the rule).
function IndexedReviewScreen:jump_section(direction)
  if self.list_view.get_active_commit then
    return self:jump_to_adjacent_commit(direction)
  end

  -- By-file: jump to the next/prev crate-level folder heading. Wraps around.
  local component = self.list_view.scene:get('list')
  local current_lnum = component:get_lnum()
  local count = component:get_line_count()
  local delta = direction == 'next' and 1 or -1
  local headings = section_headings(self.list_view.state.folds)

  for offset = 1, count do
    local target_lnum = ((current_lnum - 1 + offset * delta) % count) + 1
    local item = self.list_view:get_list_item(target_lnum)
    if item and headings[item] then
      loop.free_textlock()
      component:unlock():set_lnum(target_lnum):lock()
      return item
    end
  end
  return nil
end

-- J/K in the by-commit list pane: jump to the next commit's first file ('next')
-- or the previous commit's last file ('prev'), regardless of where in the
-- current commit the cursor sits. Wraps around.
function IndexedReviewScreen:jump_to_adjacent_commit(direction)
  loop.free_textlock()

  local entries = self.list_view:get_entries()
  if not entries then return end

  local all_files = file_navigation.build_logical_file_list(entries)
  if #all_files == 0 then return end

  local current_idx = self:get_current_file_index(all_files)
  if not current_idx then return end

  local target_idx = file_navigation.adjacent_commit_target(all_files, current_idx, direction)
  local list_item = self:goto_logical_file(all_files[target_idx])
  if not list_item then return end

  -- Wrapped past the start/end of the list: keep the new file in view.
  if direction == 'next' and target_idx < current_idx then
    self:scroll_list_to_top()
  elseif direction == 'prev' and target_idx > current_idx then
    self:scroll_list_to_bottom()
  end

  self:focus_list_item_in_diff(list_item, direction)
end

-- Move to an entry, expanding its commit if needed
-- commit_message: match by commit message (stable across rebases) instead of hash
function IndexedReviewScreen:move_to_entry_expanding_commit(filepath, commit_hash, entry_type, commit_message)
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
              if file.status.filepath == filepath then
                -- Expand this commit and re-render
                if self.list_view:set_active_commit(commit_data.commit.hash, section.title) then
                  self.list_view:render()
                  self:update_commit_message()
                end
                -- Now find and move to the entry
                return self.list_view:move_to_entry(function(e)
                  return (not entry_type or e.type == entry_type)
                    and e.status.filepath == filepath
                    and e.commit_hash == commit_data.commit.hash
                end)
              end
            end
          end
        end
      -- Handle by-file structure: section.entries
      elseif section.entries then
        for _, file in ipairs(section.entries) do
          if file.status.filepath == filepath then
            return self.list_view:move_to_entry(function(e)
              return (not entry_type or e.type == entry_type)
                and e.status.filepath == filepath
            end)
          end
        end
      end
    end
  end
  return nil
end

function IndexedReviewScreen:next_hunk()
  -- Skip if we're in the middle of a mark operation
  if self._marking then return end

  local current_index, total_hunks, position = self:get_mark_at_cursor()

  -- Move to next file only when: no hunks, inside the last hunk, or below all hunks
  local at_end = position == 'inside' and current_index >= total_hunks
  local should_change_file = not current_index or total_hunks == 0
    or at_end or position == 'below'

  if should_change_file then
    local list_item = self:move_to_next_file()
    if not list_item then return end
    self.model:set_entry_id(list_item.id)
    self.diff_view:render()
    self.diff_view:move_to_hunk(1, 'smart')
  else
    self.diff_view:next('smart')
  end
end

function IndexedReviewScreen:prev_hunk()
  -- Skip if we're in the middle of a mark operation
  if self._marking then return end

  local current_index, total_hunks, position = self:get_mark_at_cursor()

  -- Move to prev file only when: no hunks, inside the first hunk, or above all hunks
  local at_start = position == 'inside' and current_index <= 1
  local should_change_file = not current_index or total_hunks == 0
    or at_start or position == 'above'

  if should_change_file then
    local list_item = self:move_to_prev_file()
    if not list_item then return end
    self.model:set_entry_id(list_item.id)
    self.diff_view:render()
    self.diff_view:move_to_hunk(0, 'smart')
  else
    self.diff_view:prev('smart')
  end
end

-- Position the list cursor on a specific file (by filepath, optional commit_hash, and entry type)
function IndexedReviewScreen:move_list_cursor_to_file(filepath, commit_hash, entry_type)
  -- For CommitListView, expand the correct commit first
  if self.list_view.get_entries then
    self:move_to_entry_expanding_commit(filepath, commit_hash, entry_type)
    return
  end

  -- Fallback for non-commit views
  local component = self.list_view.scene:get('list')
  self.list_view:find_list_item(function(item, lnum)
    if not item.entry or not item.entry.status then return false end
    if item.entry.status.filepath ~= filepath then return false end
    if commit_hash and item.entry.commit_hash ~= commit_hash then return false end
    if entry_type and item.entry.type ~= entry_type then return false end
    loop.free_textlock()
    component:unlock():set_lnum(lnum):lock()
    return true
  end)
end

-- Navigate after a mark/unmark. Marking rewrites the section's diff — hunk
-- indices shift, and a partially marked hunk splits into remainders — so the
-- next target is found by position: the first remaining hunk starting past
-- where the marked region began (from_top, new-side line number).
--
-- Navigation order (section is a cohesive loop):
--   1. Same file if it still has hunks past the marked region
--   2. Next file in section (first hunk)
--   3. Wrap to first file in section
--   4. Section complete - stay on current file (now in opposite section)
function IndexedReviewScreen:move_to_next_target(target_entry_type, filepath, commit_hash, from_top, next_file, first_file)
  local hunk_alignment = 'smart'

  -- 1. Same file, same section: go to the first hunk past the marked region.
  -- No such hunk (the marked region was the file's last) falls through to the
  -- next file even though earlier hunks remain — they're revisited on wrap.
  local found_entry = self:move_to_entry_expanding_commit(filepath, commit_hash, target_entry_type)
  if found_entry then
    self.model:set_entry_id(found_entry.id)
    local diff = self.model:get_diff()
    loop.free_textlock()
    local target = diff and diff.marks and file_navigation.hunk_past_position(diff.marks, from_top)
    if target then
      self.diff_view:save_viewport()  -- Preserve viewport for same-file navigation
      self.diff_view:render()
      loop.free_textlock()
      self.diff_view:move_to_hunk(target, hunk_alignment)
      return
    end
  end

  -- 2. Next file in section (first hunk)
  if next_file then
    found_entry = self:move_to_entry_expanding_commit(
      next_file.filepath, next_file.commit_hash, target_entry_type)
    if found_entry then
      self.model:set_entry_id(found_entry.id)
      loop.free_textlock()
      self.diff_view:render()
      self.diff_view:move_to_hunk(1, hunk_alignment)
      return
    end
  end

  -- 3. Wrap to first file in section
  if first_file then
    found_entry = self:move_to_entry_expanding_commit(
      first_file.filepath, first_file.commit_hash, target_entry_type)
    if found_entry then
      self.model:set_entry_id(found_entry.id)
      loop.free_textlock()
      self.diff_view:render()
      self.diff_view:move_to_hunk(1, hunk_alignment)
      return
    end
  end

  -- 4. Section complete - stay on current file (now in opposite section)
  local opposite_type = target_entry_type == 'seen' and 'unseen' or 'seen'
  local current_entry = self:move_to_entry_expanding_commit(filepath, commit_hash, opposite_type)
  if current_entry then
    self.model:set_entry_id(current_entry.id)
  end

  loop.free_textlock()
  self.diff_view:render()
  self.diff_view:move_to_hunk(1, hunk_alignment)
end

-- Shared mark/unmark driver. selections: array of { index, rows } into the
-- current entry's diff. mark_as_seen: true applies (s), false reverses (u).
-- Falls back to file-level ops on hunkless diffs (e.g. a marked pure rename).
-- Serialize mark operations. The lock always clears, even if fn errors --
-- a dead coroutine must not leave the screen ignoring input forever.
function IndexedReviewScreen:with_mark_lock(fn)
  if self._marking then return end
  self._marking = true
  local ok, err = pcall(fn)
  self._marking = false
  if not ok then error(err, 0) end
end

function IndexedReviewScreen:apply_seen_change(mark_as_seen, selections)
  self:with_mark_lock(function()
    local entry = self.model:get_entry()
    if not entry then return end

    -- s only acts on unseen entries, u only on seen entries (matching which
    -- diffs their hunks come from); on the opposite section they're no-ops.
    local expected_type = mark_as_seen and 'unseen' or 'seen'
    if entry.type ~= expected_type then return end

    -- Save context before marking (entry may be removed after render)
    local current_filepath = entry.filepath
    local current_commit = entry.commit_hash

    -- New-side line where the marked region begins (from the last selection,
    -- the bottom of a visual range). Navigation lands on the first hunk past
    -- this position after the rebuild; index arithmetic alone would land back
    -- on the leading remainder of a partially marked hunk.
    local from_top = 0
    local last_selection = selections and selections[#selections]
    if last_selection then
      local diff = self.model:get_diff_for(entry)
      local mark = diff and diff.marks and diff.marks[last_selection.index]
      if mark then from_top = mark.top_relative end
    end

    -- Find adjacent files in this section BEFORE rebuilding (includes files in
    -- collapsed commits)
    local section_title = mark_as_seen and 'Unseen' or 'Seen'
    local next_file, _, first_file = self:find_adjacent_files(section_title, current_filepath, current_commit)

    if not selections then
      -- Hunkless diff: treat as whole-file operation
      if mark_as_seen then
        self.model:mark_file(entry)
      else
        self.model:unmark_file(entry)
      end
    elseif mark_as_seen then
      self.model:mark_selections(entry, selections)
    else
      self.model:unmark_selections(entry, selections)
    end

    -- The mark ran git commands; escape their fast event context before UI work
    loop.free_textlock()

    -- Clear active commit before render when unmarking (it may no longer exist)
    if not mark_as_seen and self.list_view.set_active_commit then
      self.list_view:set_active_commit(nil)
    end
    self.list_view:render()

    self:move_to_next_target(expected_type, current_filepath, current_commit, from_top, next_file, first_file)
  end)
end

-- Build the selection for the hunk under the cursor, or nil for hunkless diffs
function IndexedReviewScreen:selection_at_cursor()
  local hunk_index = self:get_current_mark_index()
  if not hunk_index then return nil end
  return { { index = hunk_index, rows = nil } }
end

function IndexedReviewScreen:mark_hunk()
  self:apply_seen_change(true, self:selection_at_cursor())
end

function IndexedReviewScreen:unmark_hunk()
  self:apply_seen_change(false, self:selection_at_cursor())
end

-- Map a visual line range in the diff buffer to per-hunk row selections;
-- a selected row takes the new side of its pair.
function IndexedReviewScreen:selections_for_range(top, bot)
  loop.free_textlock()
  return visual_selection.for_range(self.model:get_diff(), self.model:get_layout_type(), top, bot)
end

-- Unified mark/unmark file operation
-- mark_as_seen: true = mark all hunks as seen, false = unmark all hunks
function IndexedReviewScreen:set_file_seen_state(mark_as_seen)
  self:with_mark_lock(function()
    self:set_file_seen_state_locked(mark_as_seen)
  end)
end

function IndexedReviewScreen:set_file_seen_state_locked(mark_as_seen)
  local entry = self.model:get_entry()
  if not entry then return end

  local current_filepath = entry.filepath
  local current_commit = entry.commit_hash
  local current_type = entry.type

  -- The entry type we stay on if we were already viewing that state
  local same_state_type = mark_as_seen and 'seen' or 'unseen'
  -- The entry type we find next if we were viewing opposite state
  local opposite_state_type = mark_as_seen and 'unseen' or 'seen'

  -- Save the original hunk index before operation (for cursor preservation)
  local saved_hunk_index = self:get_current_mark_index() or 1
  local hunk_alignment = 'smart'

  -- Find adjacent files in the opposite-state section BEFORE rebuilding
  local next_file, prev_file = nil, nil
  if current_type == opposite_state_type then
    local target_section = opposite_state_type == 'seen' and 'Seen' or 'Unseen'
    next_file, prev_file = self:find_adjacent_files(target_section, current_filepath, current_commit)
  end

  -- Perform the mark/unmark
  if mark_as_seen then
    self.model:mark_file(entry)
  else
    self.model:unmark_file(entry)
    -- Clear active commit before render (it may no longer exist)
    if self.list_view.set_active_commit then
      self.list_view:set_active_commit(nil)
    end
  end

  -- The mark ran git commands; escape their fast event context before UI work
  loop.free_textlock()
  self.list_view:render()

  -- If we were on the same state entry (seen for mark, unseen for unmark), stay on same file and hunk
  if current_type == same_state_type then
    local found_entry = self.list_view:move_to_entry(function(e)
      if e.type ~= same_state_type then return false end
      if not e.status or e.status.filepath ~= current_filepath then return false end
      if current_commit and e.commit_hash ~= current_commit then return false end
      return true
    end)
    if found_entry then
      self.model:set_entry_id(found_entry.id)
      self.diff_view:render()
      self.diff_view:move_to_hunk(saved_hunk_index, hunk_alignment)
    end
    return
  end

  -- Navigate to next opposite-state file, or prev if on last, or stay if none left
  local found_entry
  if next_file then
    found_entry = self:move_to_entry_expanding_commit(next_file.filepath, next_file.commit_hash, opposite_state_type)
  elseif prev_file then
    found_entry = self:move_to_entry_expanding_commit(prev_file.filepath, prev_file.commit_hash, opposite_state_type)
  end

  -- If no opposite-state entries found, stay on the current file (now in same_state section)
  if not found_entry then
    found_entry = self:move_to_entry_expanding_commit(current_filepath, current_commit, same_state_type)
  end

  if found_entry and found_entry.id then
    self.model:set_entry_id(found_entry.id)
    self.diff_view:render()
    self.diff_view:move_to_hunk(nil, hunk_alignment)
  end
end

function IndexedReviewScreen:mark_file()
  self:set_file_seen_state(true)
end

function IndexedReviewScreen:unmark_file()
  self:set_file_seen_state(false)
end

function IndexedReviewScreen:reset_marks()
  if self._marking then return end

  loop.free_textlock()
  local decision = console.input('Reset all marks? (y/N) '):lower()
  if decision ~= 'yes' and decision ~= 'y' then return end

  self:with_mark_lock(function()
    self.model:reset_marks()
    -- reset_marks ran git commands; escape their fast event context
    loop.free_textlock()
    self.list_view:render()
  end)
end

function IndexedReviewScreen:toggle_focus()
  local list_component = self.scene:get('list')
  local diff_component = self.scene:get('current')

  if list_component:is_focused() then
    diff_component:focus()
    self._current_focus = 'diff'
  else
    list_component:focus()
    self._current_focus = 'list'
  end
end

function IndexedReviewScreen:handle_list_move()
  -- Skip if we're in the middle of a mark operation
  if self._marking then return end

  local list_item = self.list_view:move()
  if not list_item then return end

  -- Plain list movement (arrows, mouse clicks) never changes which commit is
  -- expanded — only deliberate navigation does (J/K commit jumps, j/k
  -- adjacent-file moves, mark/unmark), via goto_logical_file /
  -- move_to_entry_expanding_commit. Landing on a header row (commit or
  -- section, no entry id) leaves the diff pane untouched too.
  if not list_item.id then return end

  -- Skip re-render when the selected entry hasn't changed (e.g. spurious
  -- CursorMoved on window-focus transitions). Re-rendering would reset the
  -- diff cursor to hunk 1, defeating cursor preservation across tab toggles.
  if list_item.id == self.model.state.id then return end

  local hunk_alignment = 'smart'
  self.model:set_entry_id(list_item.id)
  self.diff_view:render()
  self.diff_view:move_to_hunk(nil, hunk_alignment)
end

-- Enter opens the file under the cursor. On a commit title it instead
-- toggles that commit's expansion (BaseListView's raw fold flip is
-- reconciled by the active-commit render); section headers and folders keep
-- the plain fold toggle BaseListView already applied.
function IndexedReviewScreen:handle_list_enter(item)
  if item.id then return self:open_file() end

  local is_commit_header = item.commit_hash ~= nil and item.node_type == nil
  if not is_commit_header or not self.list_view.set_active_commit then return end

  local active = self.list_view:get_active_commit()
  local is_expanded = active ~= nil
    and active.hash == item.commit_hash
    and active.section == item.section_type
  if is_expanded then
    self.list_view:set_active_commit(nil)
  else
    self.list_view:set_active_commit(item.commit_hash, item.section_type)
  end
  self.list_view:render()
  self:update_commit_message()

  -- Collapsing the previously expanded commit shifts fold lines; keep the
  -- cursor on the toggled commit's title.
  local lnum
  self.list_view:each_list_item(function(node, node_lnum)
    if node.commit_hash == item.commit_hash and node.node_type == nil and node.section_type == item.section_type then
      lnum = node_lnum
      return true
    end
  end)
  if lnum then
    loop.free_textlock()
    self.list_view.scene:get('list'):unlock():set_lnum(lnum):lock()
  end
end

-- Ensure at least one file is visible (expand first commit if needed)
-- Prefers Unseen commits to bias towards action
function IndexedReviewScreen:ensure_visible_file()
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

function IndexedReviewScreen:open_file()
  local filepath = self.model:get_abs_filepath()
  if not filepath then return end

  -- Handle deleted files: move to next file
  if not fs.exists(filepath) then
    local list_item = self:move_to_next_file()
    if not list_item then
      console.info('File has been deleted')
      return
    end
    self.model:set_entry_id(list_item.id)
    filepath = self.model:get_abs_filepath()
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
    loop.free_textlock()
    if diff_err or not diff then return end
    mark = diff.marks[1]
    if not mark then return end
  end

  Window(0):set_lnum(mark.top_relative):position_cursor('center')
  event.emit('VGitSync')
end

function IndexedReviewScreen:render(on_list_render)
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

function IndexedReviewScreen:setup_list_keymaps()
  local keymaps = self.setting:get('keymaps')

  self.list_view:set_keymap({
    {
      mode = 'n',
      mapping = keymaps.toggle_focus,
      handler = function()
        self:toggle_focus()
      end,
    },
    -- `mark_hunk` (`s`) has no target in the list pane, so bind it to an explicit
    -- no-op to keep it from falling through to a global mapping.
    {
      mode = 'n',
      mapping = { key = keymaps.mark_hunk.key, desc = 'No-op (mark hunk is diff-pane only)' },
      handler = function() end,
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
        self:move_to_adjacent_file('next')
      end, 15),
    },
    {
      mode = 'n',
      mapping = keymaps.previous,
      handler = loop.debounce_coroutine(function()
        self:move_to_adjacent_file('prev')
      end, 15),
    },
    {
      mode = 'n',
      mapping = keymaps.jump_section_next,
      handler = loop.debounce_coroutine(function()
        self:jump_section('next')
      end, 15),
    },
    {
      mode = 'n',
      mapping = keymaps.jump_section_prev,
      handler = loop.debounce_coroutine(function()
        self:jump_section('prev')
      end, 15),
    },
  })
end

function IndexedReviewScreen:setup_diff_keymaps()
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
    -- In the diff pane, J/K jump to the last/first hunk in the current file,
    -- then cross into the next/prev FILE once already at that edge (not the
    -- list's section headers, which only make sense in the list pane). Wraps.
    jump_file_next = loop.debounce_coroutine(function()
      self:jump_to_file_edge('next')
    end, 15),
    jump_file_prev = loop.debounce_coroutine(function()
      self:jump_to_file_edge('prev')
    end, 15),
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
      mapping = keymaps.jump_section_next,
      handler = handlers.jump_file_next,
    },
    {
      mode = 'n',
      mapping = keymaps.jump_section_prev,
      handler = handlers.jump_file_prev,
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

  self:setup_visual_keymaps(keymaps)
end

-- Visual-mode s/u: line-level marking. The selection endpoints must be read
-- while still in visual mode, so the handlers capture them synchronously
-- before deferring to a coroutine. In split layout only the current (right)
-- pane accepts selections; the previous pane notifies instead (its rows show
-- old content, and every change is addressable from the current pane).
function IndexedReviewScreen:setup_visual_keymaps(keymaps)
  local current_component = self.scene:get('current')

  -- Keep the debounced coroutines (not the wrappers) so destroy can close them
  self.visual_keymaps = {
    mark_lines = loop.debounce_coroutine(function(top, bot)
      self:apply_visual_seen_change_range(true, top, bot)
    end, 15),
    unmark_lines = loop.debounce_coroutine(function(top, bot)
      self:apply_visual_seen_change_range(false, top, bot)
    end, 15),
  }

  local mark_lines_handler = visual_selection.make_handler(self.visual_keymaps.mark_lines)
  local unmark_lines_handler = visual_selection.make_handler(self.visual_keymaps.unmark_lines)

  current_component:set_keymap({
    mode = 'x',
    mapping = { key = keymaps.mark_hunk.key, desc = 'Mark selected lines seen' },
  }, mark_lines_handler)
  current_component:set_keymap({
    mode = 'x',
    mapping = { key = keymaps.unmark_hunk.key, desc = 'Unmark selected lines' },
  }, unmark_lines_handler)

  if self.model:get_layout_type() == 'split' then
    local previous_component = self.scene:get('previous')
    local function notify_wrong_pane()
      self.diff_view:notify('Select lines in the right pane to mark them')
    end
    previous_component:set_keymap({
      mode = 'x',
      mapping = { key = keymaps.mark_hunk.key, desc = 'No-op (select in current pane)' },
    }, notify_wrong_pane)
    previous_component:set_keymap({
      mode = 'x',
      mapping = { key = keymaps.unmark_hunk.key, desc = 'No-op (select in current pane)' },
    }, notify_wrong_pane)
  end
end

-- Coroutine body for visual s/u once the range has been captured
function IndexedReviewScreen:apply_visual_seen_change_range(mark_as_seen, top, bot)
  local selections = self:selections_for_range(top, bot)
  if not selections then
    self.diff_view:notify('No hunks in selection')
    return
  end

  self:apply_seen_change(mark_as_seen, selections)
end

function IndexedReviewScreen:setup_keymaps()
  self:setup_list_keymaps()
  self:setup_diff_keymaps()
end

-- Reconfigure all width-dependent windows for a new list column width
-- (mouse drag on the list/diff boundary, left-list layout only). Cheap:
-- window re-plots only; content re-renders once on release.
function IndexedReviewScreen:apply_list_width(cols)
  local total = dimensions.global_width()
  cols = math.max(20, math.min(cols, total - 40))
  if cols == self.list_cols then return end
  self.list_cols = cols

  local function replot(window, col, width)
    local win_id = window and window.win_id
    if not win_id or not vim.api.nvim_win_is_valid(win_id) then return end
    local row = vim.api.nvim_win_get_config(win_id).row
    vim.api.nvim_win_set_config(win_id, { relative = 'editor', row = row, col = col, width = width })
  end

  local function replot_component(component, col, width)
    if not component then return end
    replot(component.window, col, width)
    local header = component.elements and component.elements.header
    if header then replot(header.window, col, width) end
  end

  replot_component(self.scene:get('list'), 0, cols)

  if self.commit_message_view then
    -- Future CommitMessageView:resize() calls re-derive geometry from the plot
    self.commit_message_view.plot.width = cols
    replot_component(self.scene:get('commit_message'), 0, cols)
  end

  local rest = total - cols
  if self.model:get_layout_type() == 'split' then
    local half = math.ceil(rest / 2)
    replot_component(self.scene:get('previous'), cols, half)
    replot_component(self.scene:get('current'), cols + half, rest - half)
  else
    replot_component(self.scene:get('current'), cols, rest)
  end
end

-- Re-render width-dependent content (void filler, message wrap height) after
-- a drag completes, and remember the width for screens opened later this
-- session.
function IndexedReviewScreen:finish_list_resize()
  self.setting:set('list_width', self.list_cols)

  self.diff_view:save_viewport()
  self.diff_view:render()

  if self.commit_message_view then
    self.commit_message_view.current_height = nil
    self.commit_message_view:render()
  end
end

-- Make the list/diff boundary mouse-draggable. Only active when the subclass
-- plotted a left-side list (list_cols set).
function IndexedReviewScreen:setup_drag_resize()
  if not self.list_cols then return end

  -- The handlers arrive via vim.schedule and can race destroy(); _drag_detach
  -- is non-nil exactly while the screen is alive, so gate on it.
  self._drag_detach = drag_resize.attach({
    boundary = function()
      -- First screen column of the diff pane (screen columns are 1-based)
      return self.list_cols + 1
    end,
    on_drag = function(boundary)
      if self._drag_detach then self:apply_list_width(boundary - 1) end
    end,
    on_release = loop.coroutine(function()
      if self._drag_detach then self:finish_list_resize() end
    end),
  })
end

-- Returns true if current buffer is in the review (triggers source line positioning)
function IndexedReviewScreen:focus_relative_buffer_entry(buffer)
  local review_state = self.model:get_review_state()
  local last_section, last_filepath, last_commit_message = review_state:get_position()

  -- Priority 1: Find current buffer's file, preferring saved section
  -- This keeps the review in sync with what you're editing in vim
  local filepath = buffer:get_relative_name()
  if filepath ~= '' then
    if self.list_view.get_entries then
      local found = self:move_to_entry_expanding_commit(filepath, nil, last_section, last_commit_message)
        or self:move_to_entry_expanding_commit(filepath, nil, last_section)
        or self:move_to_entry_expanding_commit(filepath, nil, nil)
      if found then return true end
    else
      local list_item = self:move_to(function(status, entry_type)
        return status.filepath == filepath and entry_type == last_section
      end) or self:move_to(function(status)
        return status.filepath == filepath
      end)
      if list_item then return true end
    end
  end

  -- Priority 2: Current buffer not in review - restore saved position
  if last_filepath then
    if self.list_view.get_entries then
      local found = self:move_to_entry_expanding_commit(last_filepath, nil, last_section, last_commit_message)
        or self:move_to_entry_expanding_commit(last_filepath, nil, last_section)
        or self:move_to_entry_expanding_commit(last_filepath, nil, nil)
      if found then return false end
    else
      local list_item = self:move_to(function(status, entry_type)
        return status.filepath == last_filepath and entry_type == last_section
      end) or self:move_to(function(status)
        return status.filepath == last_filepath
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

function IndexedReviewScreen:create(args)
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
      on_enter = function(item)
        self:handle_list_enter(item)
      end,
      on_move = function()
        self:handle_list_move()
      end,
    },
  })
  if self.commit_message_view then
    self.commit_message_view:mount()
  end

  self.list_view:set_title(self.model:get_list_title())

  self.diff_view:render()
  self.app_bar_view:render()
  self.list_view:render()
  if self.commit_message_view then
    self.commit_message_view:render()
  end

  self:setup_keymaps()
  self:setup_drag_resize()
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

function IndexedReviewScreen:on_quit()
  local is_diff_focused = (self._current_focus or 'diff') == 'diff'

  -- State is saved by destroy() below

  local filepath = self.model:get_abs_filepath()

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

function IndexedReviewScreen:destroy()
  -- Quit paths can trigger destroy several times (on_quit, BufWinLeave,
  -- QuitPre); save and tear down only once.
  if self._destroyed then return end
  self._destroyed = true

  -- Save review state before destroying (handles :q, window close, etc.)
  -- Use pcall since destroy may be called from various contexts
  local current_focus = self._current_focus
  pcall(function()
    local entry = self.model:get_entry()
    local review_state = self.model:get_review_state()
    if review_state and entry then
      local focus = current_focus or 'diff'
      local commit_message = entry.commit and entry.commit.message or nil
      review_state:save_position(entry.type, entry.filepath, commit_message, focus)
    end
    if review_state then
      review_state:save()
    end
  end)

  loop.close_debounced_handlers(self.diff_keymaps)
  self.diff_keymaps = {}
  if self.visual_keymaps then
    loop.close_debounced_handlers(self.visual_keymaps)
    self.visual_keymaps = nil
  end
  if self._drag_detach then
    self._drag_detach()
    self._drag_detach = nil
  end
  self.scene:destroy()
end

return IndexedReviewScreen
