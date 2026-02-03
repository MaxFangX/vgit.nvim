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
    _marking = false,  -- Lock to prevent concurrent mark operations
  }
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
  local component = self.list_view.scene:get('list')
  local current_lnum = component:get_lnum()
  local count = component:get_line_count()

  for offset = 1, count do
    local target_lnum = current_lnum + offset
    if target_lnum > count then target_lnum = target_lnum - count end

    local item = self.list_view:get_list_item(target_lnum)
    if item and item.entry and item.entry.status then
      component:unlock():set_lnum(target_lnum):lock()
      return item
    end
  end
  return nil
end

function ProjectReviewScreen:move_to_prev_file()
  loop.free_textlock()
  local component = self.list_view.scene:get('list')
  local current_lnum = component:get_lnum()
  local count = component:get_line_count()

  for offset = 1, count do
    local target_lnum = current_lnum - offset
    if target_lnum < 1 then target_lnum = target_lnum + count end

    local item = self.list_view:get_list_item(target_lnum)
    if item and item.entry and item.entry.status then
      component:unlock():set_lnum(target_lnum):lock()
      return item
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
  local hunk_alignment = self.setting:get('hunk_alignment')

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
  local hunk_alignment = self.setting:get('hunk_alignment')

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

-- Find entry ID for a specific file/commit/type combination
function ProjectReviewScreen:find_entry_id(filename, commit_hash, entry_type)
  local found_id = nil
  self.list_view:find_list_item(function(item)
    if not item.entry or not item.entry.status then return false end
    if item.entry.status.filename ~= filename then return false end
    if commit_hash and item.entry.commit_hash ~= commit_hash then return false end
    if entry_type and item.entry.type ~= entry_type then return false end
    found_id = item.entry.id
    return true
  end)
  return found_id
end

-- Position the list cursor on a specific file (by filename, optional commit_hash, and entry type)
function ProjectReviewScreen:move_list_cursor_to_file(filename, commit_hash, entry_type)
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

-- Find next hunk matching target_seen_state starting from a specific file/hunk
-- target_seen_state: true = find seen hunks (for auto-advance after unmarking)
--                    false = find unseen hunks (for auto-advance after marking)
function ProjectReviewScreen:move_to_hunk_matching(target_seen_state, mark_key, filename, commit_hash, from_hunk, total_hunks)
  local hunk_alignment = self.setting:get('hunk_alignment')
  local target_entry_type = target_seen_state and 'seen' or 'unseen'

  -- Get content_ids for current file
  local entry = self.model:get_entry()
  local content_ids = entry and self.model:get_content_ids(entry) or {}

  -- Check remaining hunks in the same file
  for i = from_hunk + 1, total_hunks do
    local content_id = content_ids[i]
    if content_id then
      local is_seen = self.model:is_hunk_seen(mark_key, content_id)
      if is_seen == target_seen_state then
        -- Staying in the same file - find and set the target entry
        local entry_id = self:find_entry_id(filename, commit_hash, target_entry_type)
        if entry_id then
          self:move_list_cursor_to_file(filename, commit_hash, target_entry_type)
          self.model:set_entry_id(entry_id)
          loop.free_textlock()
          self.diff_view:render()
          loop.free_textlock()
          local filtered_idx = self:get_filtered_hunk_index(i)
          loop.free_textlock()
          self.diff_view:move_to_hunk(filtered_idx, hunk_alignment)
        end
        return
      end
    end
  end

  -- All remaining hunks in this file don't match, find next file with matching hunks
  local component = self.list_view.scene:get('list')
  local count = component:get_line_count()

  for lnum = 1, count do
    local item = self.list_view:get_list_item(lnum)
    if item and item.entry and item.entry.type == target_entry_type and item.entry.status then
      local full_entry = self.model:get_entry(item.entry.id)
      if not full_entry then goto continue end

      -- Ensure diff is computed to get content_ids
      self.model:ensure_hunk_count(full_entry)
      local next_ctx = self:get_entry_context(full_entry)
      local next_content_ids = self.model:get_content_ids(full_entry)
      if #next_content_ids == 0 then goto continue end

      for i, next_content_id in ipairs(next_content_ids) do
        local is_seen = self.model:is_hunk_seen(next_ctx.mark_key, next_content_id)
        if is_seen == target_seen_state then
          loop.free_textlock()
          component:unlock():set_lnum(lnum):lock()
          self.model:set_entry_id(item.entry.id)
          self.diff_view:render()
          loop.free_textlock()
          local filtered_idx = self:get_filtered_hunk_index(i)
          loop.free_textlock()
          self.diff_view:move_to_hunk(filtered_idx, hunk_alignment)
          return
        end
      end
      ::continue::
    end
  end

  -- No matching hunks found - fall back to first entry of target type, or stay on current file
  local fallback_entry = self.list_view:find_entry(function(e)
    return e.type == target_entry_type
  end)

  if fallback_entry then
    self.list_view:move_to_entry(function(e) return e.id == fallback_entry.id end)
    self.model:set_entry_id(fallback_entry.id)
  else
    -- No entries of target type exist - find the current file in opposite section
    local opposite_type = target_seen_state and 'unseen' or 'seen'
    local current_entry = self.list_view:find_entry(function(e)
      if e.type ~= opposite_type then return false end
      if not e.status or e.status.filename ~= filename then return false end
      if commit_hash and e.commit_hash ~= commit_hash then return false end
      return true
    end)
    if current_entry then
      self.list_view:move_to_entry(function(e) return e.id == current_entry.id end)
      self.model:set_entry_id(current_entry.id)
    end
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

  self.model:mark_hunk(ctx.mark_key, content_id)
  self.list_view:render()

  -- Navigate to next unmarked hunk using saved context
  self:move_to_hunk_matching(false, current_mark_key, current_filename, current_commit, current_hunk, total_hunks)
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

  self.model:unmark_hunk(ctx.mark_key, content_id)
  self.list_view:render()

  -- Navigate to next marked hunk using saved context
  self:move_to_hunk_matching(true, current_mark_key, current_filename, current_commit, current_hunk, total_hunks)
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
  local hunk_alignment = self.setting:get('hunk_alignment')

  -- Perform the mark/unmark using mark_key (filename only)
  if mark_as_seen then
    self.model:mark_file(ctx.mark_key)
  else
    self.model:unmark_file(ctx.mark_key)
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

  -- We were on opposite state entry - find the next file with opposite state
  local target_filename, target_commit = nil, nil
  local found_current = false

  self.list_view:each_list_item(function(node)
    if not node.entry or not node.entry.status then return end
    local item_entry = node.entry
    if item_entry.type == opposite_state_type then
      local item_filename = item_entry.status.filename
      local is_current = item_filename == current_filename
        and (not current_commit or item_entry.commit_hash == current_commit)
      if found_current and not target_filename then
        target_filename = item_filename
        target_commit = item_entry.commit_hash
      end
      if is_current then
        found_current = true
      end
    end
  end)

  -- Navigate to next opposite-state file, or first opposite-state if none after current
  local found_entry
  if target_filename then
    found_entry = self.list_view:move_to_entry(function(e)
      if e.type ~= opposite_state_type then return false end
      if not e.status or e.status.filename ~= target_filename then return false end
      if target_commit and e.commit_hash ~= target_commit then return false end
      return true
    end)
  end
  if not found_entry then
    found_entry = self.list_view:find_entry(function(e)
      return e.type == opposite_state_type
    end)
    if found_entry then
      self.list_view:move_to_entry(function(e)
        return e.id == found_entry.id
      end)
    end
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
    local hunk_alignment = self.setting:get('hunk_alignment')
    diff_component:focus()
    self.diff_view:move_to_hunk(1, hunk_alignment)
  else
    list_component:focus()
  end
end

function ProjectReviewScreen:handle_list_move()
  -- Skip if we're in the middle of a mark operation
  if self._marking then return end

  local list_item = self.list_view:move()
  if not list_item then return end

  local hunk_alignment = self.setting:get('hunk_alignment')
  self.model:set_entry_id(list_item.id)
  self.diff_view:render()
  self.diff_view:move_to_hunk(nil, hunk_alignment)
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

  local hunk_alignment = self.setting:get('hunk_alignment')
  self.diff_view:render()
  self.diff_view:move_to_hunk(nil, hunk_alignment)
end

function ProjectReviewScreen:setup_list_keymaps()
  local keymaps = self.setting:get('keymaps')

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
        local hunk_alignment = self.setting:get('hunk_alignment')
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
        local hunk_alignment = self.setting:get('hunk_alignment')
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

-- Returns true if current buffer is in the review, false otherwise
function ProjectReviewScreen:focus_relative_buffer_entry(buffer)
  local review_state = self.model:get_review_state()
  local last_section, last_filename = review_state:get_position()

  -- Try to find current buffer's file in the review
  local filename = buffer:get_relative_name()
  if filename ~= '' then
    -- Prefer the section we were last viewing
    local list_item = self:move_to(function(status, entry_type)
      return status.filename == filename and entry_type == last_section
    end)
    if list_item then
      return true
    end

    -- Fall back to any section
    list_item = self:move_to(function(status)
      return status.filename == filename
    end)
    if list_item then
      return true
    end
  end

  -- Current buffer not in review - try to restore to last viewed file
  if last_filename then
    local list_item = self:move_to(function(status, entry_type)
      return status.filename == last_filename and entry_type == last_section
    end)
    if list_item then return false end

    list_item = self:move_to(function(status)
      return status.filename == last_filename
    end)
    if list_item then return false end
  end

  -- Fallback: prefer unseen entries
  local found = self:move_to(function(_, entry_type)
    return entry_type == 'unseen'
  end)
  if not found then
    self:move_to(function()
      return true
    end)
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

  self.diff_view:render()
  self.app_bar_view:render()
  self.list_view:render()

  self:setup_keymaps()
  local found_current_buffer = self:focus_relative_buffer_entry(buffer)
  self:handle_list_move()
  self:toggle_focus()

  -- Position cursor at source file line (must be after toggle_focus which resets to first hunk)
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
  local diff_component = self.scene:get('current')
  if not diff_component:is_focused() then
    return false
  end

  local entry = self.model:get_entry()
  local filepath = self.model:get_filepath()
  local file_lnum = self.diff_view:get_file_lnum()
  local diff_winline = vim.fn.winline()

  -- Save section and filename for fallback when re-entering from a non-review file
  local review_state = self.model:get_review_state()
  if review_state and entry then
    review_state:save_position(entry.type, entry.filename)
  end

  -- Save state to disk before closing
  if review_state then
    review_state:save()
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

  if file_lnum then
    Window(0):set_lnum(file_lnum)
    -- Restore scroll position so cursor is at same relative position in window
    local target_top = file_lnum - diff_winline + 1
    if target_top >= 1 then
      vim.fn.winrestview({ topline = target_top })
    end
  end

  event.emit('VGitSync')
  return true
end

function ProjectReviewScreen:destroy()
  loop.close_debounced_handlers(self.diff_keymaps)
  self.diff_keymaps = {}
  self.scene:destroy()
end

return ProjectReviewScreen
