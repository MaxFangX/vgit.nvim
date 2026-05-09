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
local StatusListView = require('vgit.ui.views.StatusListView')
local KeyHelpBarView = require('vgit.ui.views.KeyHelpBarView')
local Model = require('vgit.features.screens.ProjectDiffScreen.Model')
local section_headings = require('vgit.ui.views.StatusListView.section_headings')
local project_diff_preview_setting = require('vgit.settings.project_diff_preview')
local file_navigation = require('vgit.features.screens.file_navigation')

local ProjectDiffScreen = Object:extend()

-- Entry-type predicates for find_adjacent_files / navigate_after_op.
local function is_unstaged(t) return t == 'unstaged' end
local function is_staged(t) return t == 'staged' end
local function is_unstaged_or_unmerged(t) return t == 'unstaged' or t == 'unmerged' end

function ProjectDiffScreen:constructor(opts)
  opts = opts or {}

  local scene = Scene()
  local model = Model(opts)

  return {
    name = 'Project Diff Screen',
    scene = scene,
    model = model,
    diff_keymaps = {}, -- Store debounced diff keymap handlers for cleanup
    app_bar_view = KeyHelpBarView(scene, {
      keymaps = function()
        local keymaps = project_diff_preview_setting:get('keymaps')
        return {
          { 'Stage',        keymaps['buffer_stage'] },
          { 'Unstage',      keymaps['buffer_unstage'] },
          { 'Reset',        keymaps['buffer_reset'] },
          { 'Stage hunk',   keymaps['buffer_hunk_stage'] },
          { 'Unstage hunk', keymaps['buffer_hunk_unstage'] },
          { 'Reset hunk',   keymaps['buffer_hunk_reset'] },
          { 'Next',         keymaps['next'] },
          { 'Previous',     keymaps['previous'] },
          { 'Jump section', keymaps['jump_section_next'] },
          { 'Stage all',    keymaps['stage_all'] },
          { 'Unstage all',  keymaps['unstage_all'] },
          { 'Reset all',    keymaps['reset_all'] },
          { 'Commit',       keymaps['commit'] },
        }
      end,
    }),
    diff_view = DiffView(scene, {
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
    }, {
      row = 1,
      col = '25vw',
      width = '75vw',
    }, {
      elements = {
        header = true,
        footer = false,
      },
    }),
    status_list_view = StatusListView(scene, {
      entries = function()
        return model:get_entries()
      end,
    }, {
      row = 1,
      width = '25vw',
    }, {
      elements = {
        header = false,
        footer = false,
      },
    }),
  }
end

function ProjectDiffScreen:move_to(query_fn)
  return self.status_list_view:move_to(query_fn)
end

-- Find adjacent files matching `type_predicate` (function(entry_type) -> bool)
-- in the logical entry list (independent of which folders are expanded).
-- Returns next_file, prev_file, first_file as { filepath } tables (or nil),
-- where first_file enables wrap-around to the start of the section.
function ProjectDiffScreen:find_adjacent_files(filepath, type_predicate)
  local entries = self.model:get_entries()
  if not entries then return nil, nil, nil end

  local all_files = file_navigation.build_logical_file_list(entries)
  return file_navigation.find_adjacent_files(all_files, filepath, nil, function(info)
    return type_predicate(info.file.type)
  end)
end

-- Render variant for hunk operations that maintains cursor position.
-- If still on the same file/entry after the operation, restores viewport and
-- moves to the same hunk index. Otherwise, renders normally with first hunk.
function ProjectDiffScreen:render_stable(on_status_list_render, filepath, entry_type, hunk_index)
  local entries = self.model:fetch()
  loop.free_textlock()

  if utils.object.is_empty(entries) then return self:destroy() end

  self.status_list_view:render()
  if on_status_list_render then on_status_list_render() end

  local list_item = self.status_list_view:get_current_list_item()
  self.model:set_entry_id(list_item.id)

  local new_entry = self.model:get_entry()
  local same_file = new_entry
    and new_entry.type == entry_type
    and new_entry.status.filepath == filepath

  if same_file then
    -- Save viewport before render so we can restore scroll position
    self.diff_view:save_viewport()
    self.diff_view:render()
    local diff = self.model:get_diff()
    if diff and diff.marks and #diff.marks > 0 then
      local target = math.min(hunk_index, #diff.marks)
      self.diff_view:move_to_hunk(target, 'smart')
    end
  else
    self.diff_view:render()
    local hunk_alignment = project_diff_preview_setting:get('hunk_alignment')
    self.diff_view:move_to_hunk(1, hunk_alignment)
  end
end

-- After a stage/unstage/reset op, decide where the cursor should land.
-- Tries in order, all filtered by type_predicate (e.g. is_unstaged):
--   1. stay on current file (e.g. partial hunk stage left more hunks)
--   2. next match
--   3. wrap to first match
--   4. prev match (in case section was walked non-linearly)
-- Falls back to current file in any section if none of the above match.
function ProjectDiffScreen:navigate_after_op(filepath, type_predicate, next_file, prev_file, first_file)
  local function try(target)
    return target and self:move_to(function(status, entry_type)
      return status.filepath == target.filepath and type_predicate(entry_type)
    end) ~= nil
  end

  if try({ filepath = filepath }) then return end
  if try(next_file) then return end
  if try(first_file) then return end
  if try(prev_file) then return end

  self:move_to(function(status) return status.filepath == filepath end)
end

function ProjectDiffScreen:stage_hunk()
  local entry = self.model:get_entry()
  if not entry then return end
  if entry.type ~= 'unstaged' then return end

  loop.free_textlock()
  local hunk, hunk_index = self.diff_view:get_hunk_under_cursor()
  if not hunk then return end

  local filepath = entry.status.filepath
  local next_file, prev_file, first_file = self:find_adjacent_files(filepath, is_unstaged)

  local _, err = self.model:stage_hunk(filepath, hunk)
  if err then
    console.debug.error(err)
    return
  end

  self:render_stable(function()
    self:navigate_after_op(filepath, is_unstaged, next_file, prev_file, first_file)
  end, filepath, 'unstaged', hunk_index)
end

function ProjectDiffScreen:unstage_hunk()
  local entry = self.model:get_entry()
  if not entry then return end
  if entry.type ~= 'staged' then return end

  loop.free_textlock()
  local hunk, hunk_index = self.diff_view:get_hunk_under_cursor()
  if not hunk then return end

  local filepath = entry.status.filepath
  local next_file, prev_file, first_file = self:find_adjacent_files(filepath, is_staged)

  local _, err = self.model:unstage_hunk(filepath, hunk)
  if err then
    console.debug.error(err)
    return
  end

  self:render_stable(function()
    self:navigate_after_op(filepath, is_staged, next_file, prev_file, first_file)
  end, filepath, 'staged', hunk_index)
end

function ProjectDiffScreen:reset_hunk()
  local entry = self.model:get_entry()
  if not entry then return end
  if entry.type ~= 'unstaged' then return end

  loop.free_textlock()
  local hunk, hunk_index = self.diff_view:get_hunk_under_cursor()
  if not hunk then return end

  local filepath = entry.status.filepath
  local next_file, prev_file, first_file = self:find_adjacent_files(filepath, is_unstaged)

  loop.free_textlock()
  local decision = console.input('Are you sure you want to discard this hunk? (y/N) '):lower()
  if decision ~= 'yes' and decision ~= 'y' then return end

  loop.free_textlock()
  local _, err = self.model:reset_hunk(filepath, hunk)
  if err then
    console.debug.error(err)
    return
  end

  self:render_stable(function()
    self:navigate_after_op(filepath, is_unstaged, next_file, prev_file, first_file)
  end, filepath, 'unstaged', hunk_index)
end

function ProjectDiffScreen:stage_file()
  local entry = self.model:get_entry()
  if not entry then return end
  if entry.type ~= 'unstaged' and entry.type ~= 'unmerged' then return end

  loop.free_textlock()
  local filepath = entry.status.filepath
  local next_file, prev_file, first_file = self:find_adjacent_files(filepath, is_unstaged_or_unmerged)

  local _, err = self.model:stage_file(filepath)
  if err then
    console.debug.error(err)
    return
  end

  self:render(function()
    self:navigate_after_op(filepath, is_unstaged_or_unmerged, next_file, prev_file, first_file)
  end)
end

function ProjectDiffScreen:unstage_file()
  local entry = self.model:get_entry()
  if not entry then return end
  if entry.type ~= 'staged' then return end

  loop.free_textlock()
  local filepath = entry.status.filepath
  local next_file, prev_file, first_file = self:find_adjacent_files(filepath, is_staged)

  local _, err = self.model:unstage_file(filepath)
  if err then
    console.debug.error(err)
    return
  end

  self:render(function()
    self:navigate_after_op(filepath, is_staged, next_file, prev_file, first_file)
  end)
end

function ProjectDiffScreen:stage_all()
  local _, err = self.model:stage_all()
  if err then
    console.debug.error(err)
    return
  end

  local entry = self.model:get_entry()
  self:render(function()
    if not entry then return end
    self:move_to(function(status)
      return status.filepath == entry.status.filepath
    end)
  end)
end

function ProjectDiffScreen:unstage_all()
  local _, err = self.model:unstage_all()
  if err then
    console.debug.error(err)
    return
  end

  local entry = self.model:get_entry()
  self:render(function()
    if not entry then return end
    self:move_to(function(status)
      return status.filepath == entry.status.filepath
    end)
  end)
end

function ProjectDiffScreen:commit()
  self:destroy()
  vim.cmd('VGit project_commit_preview')
end

function ProjectDiffScreen:reset_file()
  local filepath = self.model:get_filepath()
  if not filepath then return end

  loop.free_textlock()
  local decision =
      console.input(string.format('Are you sure you want to discard changes in %s? (y/N) ', filepath)):lower()

  if decision ~= 'yes' and decision ~= 'y' then return end

  loop.free_textlock()
  local _, err = self.model:reset_file(filepath)
  loop.free_textlock()

  if err then
    console.debug.error(err)
    return
  end

  self:render()
end

function ProjectDiffScreen:reset_all()
  loop.free_textlock()
  local decision = console.input('Are you sure you want to discard all unstaged changes? (y/N) '):lower()

  if decision ~= 'yes' and decision ~= 'y' then return end

  loop.free_textlock()
  local _, err = self.model:reset_all()
  loop.free_textlock()

  if err then
    console.debug.error(err)
    return
  end

  self:render()
end

function ProjectDiffScreen:enter_view()
  local mark = self.diff_view:get_current_mark_under_cursor()
  if not mark then return end

  local abs_filepath = self.model:get_abs_filepath()
  loop.free_textlock()
  if not abs_filepath then return end

  self:destroy()

  fs.open(abs_filepath)
  Window(0):set_lnum(mark.top_relative):position_cursor('center')

  event.emit('VGitSync')
end

function ProjectDiffScreen:open_file()
  local abs_filepath = self.model:get_abs_filepath()
  if not abs_filepath then return end

  local mark = self.diff_view:get_current_mark_under_cursor()

  loop.free_textlock()
  self:destroy()
  fs.open(abs_filepath)

  if not mark then
    local diff, diff_err = self.model:get_diff()
    if diff_err or not diff then return end
    mark = diff.marks[1]
    if not mark then return end
  end

  Window(0):set_lnum(mark.top_relative):position_cursor('center')

  event.emit('VGitSync')
end

function ProjectDiffScreen:render(on_status_list_render)
  local entries = self.model:fetch()
  loop.free_textlock()

  if utils.object.is_empty(entries) then return self:destroy() end

  self.status_list_view:render()
  if on_status_list_render then on_status_list_render() end

  local list_item = self.status_list_view:get_current_list_item()
  self.model:set_entry_id(list_item.id)

  local hunk_alignment = project_diff_preview_setting:get('hunk_alignment')
  self.diff_view:render()
  self.diff_view:move_to_hunk(nil, hunk_alignment)
end

function ProjectDiffScreen:handle_list_move()
  local list_item = self.status_list_view:move()
  if not list_item then return end

  -- Skip re-render when selection didn't change (preserves diff cursor across
  -- tab toggles when CursorMoved fires spuriously on focus transitions).
  if list_item.id == self.model.state.id then return end

  local hunk_alignment = project_diff_preview_setting:get('hunk_alignment')
  self.model:set_entry_id(list_item.id)
  self.diff_view:render()
  self.diff_view:move_to_hunk(nil, hunk_alignment)
end

function ProjectDiffScreen:get_current_mark_index()
  loop.free_textlock()
  return self.diff_view:get_cursor_mark_position()
end

function ProjectDiffScreen:move_to_next_file()
  loop.free_textlock()
  local component = self.status_list_view.scene:get('list')
  local current_lnum = component:get_lnum()
  local count = component:get_line_count()

  -- Find next file entry (skip folders)
  for offset = 1, count do
    local target_lnum = current_lnum + offset
    if target_lnum > count then target_lnum = target_lnum - count end

    local item = self.status_list_view:get_list_item(target_lnum)
    if item and item.entry and item.entry.status then
      component:unlock():set_lnum(target_lnum):lock()
      return item
    end
  end
  return nil
end

function ProjectDiffScreen:move_to_prev_file()
  loop.free_textlock()
  local component = self.status_list_view.scene:get('list')
  local current_lnum = component:get_lnum()
  local count = component:get_line_count()

  -- Find previous file entry (skip folders)
  for offset = 1, count do
    local target_lnum = current_lnum - offset
    if target_lnum < 1 then target_lnum = target_lnum + count end

    local item = self.status_list_view:get_list_item(target_lnum)
    if item and item.entry and item.entry.status then
      component:unlock():set_lnum(target_lnum):lock()
      return item
    end
  end
  return nil
end

function ProjectDiffScreen:jump_section(direction)
  loop.free_textlock()
  local component = self.status_list_view.scene:get('list')
  local headings = section_headings(self.status_list_view.state.folds)

  local current_lnum = component:get_lnum()
  local count = component:get_line_count()
  local delta = direction == 'next' and 1 or -1

  for offset = 1, count do
    local target_lnum = ((current_lnum - 1 + offset * delta) % count) + 1
    local item = self.status_list_view:get_list_item(target_lnum)
    if item and headings[item] then
      component:unlock():set_lnum(target_lnum):lock()
      return item
    end
  end
end

function ProjectDiffScreen:next_hunk()
  local current_index, total_hunks, position = self:get_current_mark_index()

  -- Move to next file only when: no hunks, inside the last hunk, or below all hunks
  local at_end = position == 'inside' and current_index >= total_hunks
  local should_change_file = not current_index or total_hunks == 0
    or at_end or position == 'below'

  if should_change_file then
    local list_item = self:move_to_next_file()
    if not list_item then return end
    self.model:set_entry_id(list_item.id)
    self.diff_view:render()
    local hunk_alignment = project_diff_preview_setting:get('hunk_alignment')
    self.diff_view:move_to_hunk(1, hunk_alignment)
  else
    self.diff_view:next('smart')
  end
end

function ProjectDiffScreen:prev_hunk()
  local current_index, total_hunks, position = self:get_current_mark_index()

  -- Move to prev file only when: no hunks, inside the first hunk, or above all hunks
  local at_start = position == 'inside' and current_index <= 1
  local should_change_file = not current_index or total_hunks == 0
    or at_start or position == 'above'

  if should_change_file then
    local list_item = self:move_to_prev_file()
    if not list_item then return end
    self.model:set_entry_id(list_item.id)
    self.diff_view:render()
    local hunk_alignment = project_diff_preview_setting:get('hunk_alignment')
    self.diff_view:move_to_hunk(0, hunk_alignment)
  else
    self.diff_view:prev('smart')
  end
end

-- Returns true if current buffer is in the diff, false otherwise
function ProjectDiffScreen:focus_relative_buffer_entry(buffer)
  local filepath = buffer:get_relative_name()
  local last_entry_type = vim.b[buffer.bufnr].vgit_last_entry_type

  -- Try to find current buffer's file
  if filepath ~= '' then
    -- If we have a hint from last quit, prefer that entry type
    if last_entry_type then
      local list_item = self:move_to(function(status, entry_type)
        return status.filepath == filepath and entry_type == last_entry_type
      end)
      if list_item then return true end
    end

    -- Otherwise prefer unstaged
    local list_item = self:move_to(function(status, entry_type)
      return status.filepath == filepath and entry_type == 'unstaged'
    end)
    if list_item then return true end

    -- Fall back to any entry for this file
    list_item = self:move_to(function(status)
      return status.filepath == filepath
    end)
    if list_item then return true end
  end

  -- Fallback: prefer unstaged entries, then any entry
  local found = self:move_to(function(_, entry_type)
    return entry_type == 'unstaged'
  end)
  if not found then
    self:move_to(function()
      return true
    end)
  end
  return false
end

function ProjectDiffScreen:toggle_focus()
  local list_component = self.scene:get('list')
  local diff_component = self.scene:get('current')

  if list_component:is_focused() then
    diff_component:focus()
  else
    list_component:focus()
  end
end

function ProjectDiffScreen:setup_list_keymaps()
  local keymaps = project_diff_preview_setting:get('keymaps')

  self.status_list_view:set_keymap({
    {
      mode = 'n',
      mapping = keymaps.commit,
      handler = loop.coroutine(function()
        self:commit()
      end),
    },
    {
      mode = 'n',
      mapping = keymaps.buffer_reset,
      handler = loop.coroutine(function()
        self:reset_file()
      end),
    },
    {
      mode = 'n',
      mapping = keymaps.buffer_stage,
      handler = loop.coroutine(function()
        self:stage_file()
      end),
    },
    {
      mode = 'n',
      mapping = keymaps.buffer_unstage,
      handler = loop.coroutine(function()
        self:unstage_file()
      end),
    },
    {
      mode = 'n',
      mapping = keymaps.stage_all,
      handler = loop.coroutine(function()
        self:stage_all()
      end),
    },
    {
      mode = 'n',
      mapping = keymaps.unstage_all,
      handler = loop.coroutine(function()
        self:unstage_all()
      end),
    },
    {
      mode = 'n',
      mapping = keymaps.reset_all,
      handler = loop.coroutine(function()
        self:reset_all()
      end),
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
      handler = loop.debounce_coroutine(function()
        local list_item = self:move_to_next_file()
        if not list_item then return end
        self.model:set_entry_id(list_item.id)
        local hunk_alignment = project_diff_preview_setting:get('hunk_alignment')
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
        local hunk_alignment = project_diff_preview_setting:get('hunk_alignment')
        self.diff_view:render()
        self.diff_view:move_to_hunk(0, hunk_alignment)
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

function ProjectDiffScreen:setup_diff_keymaps()
  local keymaps = project_diff_preview_setting:get('keymaps')

  -- Create debounced handlers and store them for cleanup
  local handlers = {
    hunk_stage = loop.debounce_coroutine(function()
      self:stage_hunk()
    end, 15),
    hunk_unstage = loop.debounce_coroutine(function()
      self:unstage_hunk()
    end, 15),
    hunk_reset = loop.debounce_coroutine(function()
      self:reset_hunk()
    end, 15),
    reset = loop.debounce_coroutine(function()
      self:reset_file()
    end, 15),
    stage = loop.debounce_coroutine(function()
      self:stage_file()
    end, 15),
    unstage = loop.debounce_coroutine(function()
      self:unstage_file()
    end, 15),
    stage_all = loop.debounce_coroutine(function()
      self:stage_all()
    end, 15),
    unstage_all = loop.debounce_coroutine(function()
      self:unstage_all()
    end, 15),
    reset_all = loop.debounce_coroutine(function()
      self:reset_all()
    end, 15),
    commit = loop.debounce_coroutine(function()
      self:commit()
    end, 15),
    enter = loop.coroutine(function()
      self:enter_view()
    end),
    next_hunk = loop.debounce_coroutine(function()
      self:next_hunk()
    end, 15),
    prev_hunk = loop.debounce_coroutine(function()
      self:prev_hunk()
    end, 15),
    jump_section_next = loop.debounce_coroutine(function()
      self:jump_section('next')
    end, 15),
    jump_section_prev = loop.debounce_coroutine(function()
      self:jump_section('prev')
    end, 15),
  }

  self.diff_keymaps = handlers

  self.diff_view:set_keymap({
    {
      mode = 'n',
      mapping = keymaps.buffer_hunk_stage,
      handler = handlers.hunk_stage,
    },
    {
      mode = 'n',
      mapping = keymaps.buffer_hunk_unstage,
      handler = handlers.hunk_unstage,
    },
    {
      mode = 'n',
      mapping = keymaps.buffer_hunk_reset,
      handler = handlers.hunk_reset,
    },
    {
      mode = 'n',
      mapping = keymaps.buffer_reset,
      handler = handlers.reset,
    },
    {
      mode = 'n',
      mapping = keymaps.buffer_stage,
      handler = handlers.stage,
    },
    {
      mode = 'n',
      mapping = keymaps.buffer_unstage,
      handler = handlers.unstage,
    },
    {
      mode = 'n',
      mapping = keymaps.stage_all,
      handler = handlers.stage_all,
    },
    {
      mode = 'n',
      mapping = keymaps.unstage_all,
      handler = handlers.unstage_all,
    },
    {
      mode = 'n',
      mapping = keymaps.reset_all,
      handler = handlers.reset_all,
    },
    {
      mode = 'n',
      mapping = keymaps.commit,
      handler = handlers.commit,
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
      handler = handlers.jump_section_next,
    },
    {
      mode = 'n',
      mapping = keymaps.jump_section_prev,
      handler = handlers.jump_section_prev,
    },
    {
      mode = 'n',
      mapping = {
        key = '<enter>',
        desc = 'Open buffer'
      },
      handler = handlers.enter,
    },
  })
end

function ProjectDiffScreen:setup_keymaps()
  self:setup_list_keymaps()
  self:setup_diff_keymaps()
end

function ProjectDiffScreen:create()
  local buffer = Buffer(0)
  -- Capture cursor position and window BEFORE mounting any views
  local source_cursor_lnum = vim.fn.line('.')
  local source_cursor_col = vim.fn.col('.')
  local source_winline = vim.fn.winline()
  local source_win_id = vim.api.nvim_get_current_win()

  local data, err = self.model:fetch()
  loop.free_textlock()

  if err then
    console.debug.error(err).error(err)
    return false
  end

  if utils.object.is_empty(data) then
    if self.model:conflict_status() then
      console.info('All conflicts fixed but you are still merging')
      return false
    end
    console.info('No changes found')
    return false
  end

  self.app_bar_view:define()
  self.diff_view:define()
  self.status_list_view:define()

  self.diff_view:mount()
  self.app_bar_view:mount()
  self.status_list_view:mount({
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
  self.status_list_view:render()

  self:setup_keymaps()
  local found_current_buffer = self:focus_relative_buffer_entry(buffer)
  self:handle_list_move()
  self:toggle_focus()

  -- Position cursor at source file line (must be after handle_list_move which resets to first hunk)
  if found_current_buffer then
    vim.schedule(function()
      self.diff_view:set_source_lnum(source_cursor_lnum, source_cursor_col, source_winline)
    end)
  end

  -- Store source window for returning on quit
  self.source_win_id = source_win_id

  return true
end

-- Called when quit key is pressed. Returns true if quit was handled.
function ProjectDiffScreen:on_quit()
  local diff_component = self.scene:get('current')
  if not diff_component:is_focused() then
    return false
  end

  local abs_filepath = self.model:get_abs_filepath()
  if not abs_filepath then
    return false
  end

  local entry = self.model:get_entry()
  local file_lnum = self.diff_view:get_file_lnum()
  local diff_winline = vim.fn.winline()
  loop.free_textlock()

  local source_win_id = self.source_win_id
  self:destroy()

  -- Return to the original window if it still exists
  if source_win_id and vim.api.nvim_win_is_valid(source_win_id) then
    vim.api.nvim_set_current_win(source_win_id)
  end

  fs.open(abs_filepath)

  -- Store entry type so re-opening returns to same entry
  if entry then
    vim.b.vgit_last_entry_type = entry.type
  end

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

function ProjectDiffScreen:destroy()
  -- Clean up timer handles from debounced keymap handlers
  loop.close_debounced_handlers(self.diff_keymaps)
  self.diff_keymaps = {}

  self.scene:destroy()
end

return ProjectDiffScreen
