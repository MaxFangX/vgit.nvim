local loop = require('vgit.core.loop')
local utils = require('vgit.core.utils')
local Object = require('vgit.core.Object')
local console = require('vgit.core.console')
local dimensions = require('vgit.ui.dimensions')
local signs_setting = require('vgit.settings.signs')
local symbols_setting = require('vgit.settings.symbols')
local DiffComponent = require('vgit.ui.components.DiffComponent')

local DiffView = Object:extend()

-- Compensates for tabline taking screen space but not being accounted for
-- in floating window positioning with relative='editor'. Needs 2 lines because
-- the diff content is pushed down by the HeaderElement.
function DiffView:get_tabline_padding()
  if vim.o.showtabline > 0 then return 2 end
  return 0
end

function DiffView:get_initial_state()
  return {
    current_lines_changes = {},
    previous_lines_changes = {},
  }
end

function DiffView:constructor(scene, props, plot, config)
  return {
    scene = scene,
    plot = plot,
    props = props,
    config = config or {},
    state = DiffView:get_initial_state(),
    _saved_viewport = nil,  -- Saved viewport for smart positioning across render()
    _saved_viewport_previous = nil,  -- Saved viewport for previous (split) component
  }
end

-- Capture viewport state from a component's window
local function capture_viewport(component)
  if not component or not component.window then return nil end
  local viewport = {}
  component.window:call(function()
    local view = vim.fn.winsaveview()
    viewport.topline = view.topline
    viewport.lnum = view.lnum
    viewport.col = view.col
  end)
  return viewport
end

-- Save current viewport before render() for smart positioning
function DiffView:save_viewport()
  self._saved_viewport = capture_viewport(self.scene:get('current'))
  if self.props.layout_type() == 'split' then
    self._saved_viewport_previous = capture_viewport(self.scene:get('previous'))
  end
end

function DiffView:define()
  if self.props.layout_type() == 'unified' then
    self.scene:set(
      'current',
      DiffComponent({
        config = {
          elements = utils.object.assign({
            header = true,
            footer = false,
          }, self.config.elements),
          win_options = {
            cursorbind = true,
            scrollbind = true,
            cursorline = true,
          },
          win_plot = dimensions.relative_win_plot(self.plot, {
            height = '100vh',
            width = '100vw',
          }),
        },
      })
    )
  end

  if self.props.layout_type() == 'split' then
    self.scene:set(
      'previous',
      DiffComponent({
        config = {
          elements = utils.object.assign({
            header = true,
            footer = false,
          }, self.config.elements),
          win_options = {
            cursorbind = true,
            scrollbind = true,
            cursorline = true,
          },
          win_plot = dimensions.relative_win_plot(self.plot, {
            height = '100vh',
            width = '50vw',
          }),
        },
      })
    )
    self.scene:set(
      'current',
      DiffComponent({
        config = {
          elements = utils.object.assign({
            header = true,
            footer = false,
          }, self.config.elements),
          win_options = {
            cursorbind = true,
            scrollbind = true,
            cursorline = true,
          },
          win_plot = dimensions.relative_win_plot(self.plot, {
            height = '100vh',
            width = '50vw',
            col = '50vw',
            zindex = 4,
          }),
        },
      })
    )
  end
end

function DiffView:get_components()
  if self.props.layout_type() == 'split' then return { self.scene:get('previous'), self.scene:get('current') } end
  return { self.scene:get('current') }
end

function DiffView:set_keymap(configs)
  if self.props.layout_type() == 'split' then
    utils.list.each(configs, function(config)
      self.scene:get('previous'):set_keymap(config, config.handler)
    end)
  end

  utils.list.each(configs, function(config)
    self.scene:get('current'):set_keymap(config, config.handler)
  end)
end

function DiffView:render_word_diff(component_type, line_changes, lnum)
  local lnum_change = line_changes.lnum_change
  if not lnum_change then return end

  local word_diff = lnum_change.word_diff
  if not word_diff then return end

  local offset = 0
  local texts = {}
  local change_type = lnum_change.type
  local component = self.scene:get(component_type)
  local num_word_diff = #word_diff

  for j = 1, num_word_diff do
    local segment = word_diff[j]
    local operation, fragment = unpack(segment)

    if operation == -1 then
      local hl = change_type == 'remove' and 'GitWordDelete' or 'GitWordAdd'
      texts[#texts + 1] = { fragment, hl }
    elseif operation == 0 then
      texts[#texts + 1] = {
        fragment,
        nil,
      }
    end

    if operation == 0 or operation == -1 then offset = offset + #fragment end
  end

  component:place_extmark_text({
    texts = texts,
    col = 0,
    row = lnum - 1,
  })
end

function DiffView:render_line_diff(component_type, line_changes, lnum)
  local line_number_hl = 'GitLineNr'
  local signs_usage_setting = signs_setting:get('usage')
  local scene_signs = signs_usage_setting.scene
  local main_signs = signs_usage_setting.main
  local component = self.scene:get(component_type)

  local lnum_change = line_changes.lnum_change
  if not lnum_change then return end

  -- Use the passed lnum (already accounts for padding) instead of lnum_change.lnum
  local change_type = lnum_change.type
  local sign_name = scene_signs[change_type]

  if change_type ~= 'void' then line_number_hl = main_signs[change_type] end

  if sign_name then
    component:place_extmark_sign({
      col = lnum - 1,
      name = sign_name,
    })
  end

  if change_type == 'void' then
    local text = string.rep(symbols_setting:get('void'), component.window:get_width())
    component:place_extmark_text({
      text = text,
      hl = line_number_hl,
      row = lnum - 1,
      col = 0,
    })
  end
end

function DiffView:render_diff(top, bot)
  local padding = self:get_tabline_padding()
  top = top or 1 + padding
  bot = bot or #self.state.current_lines_changes

  local current_lines_changes = self.state.current_lines_changes
  local previous_lines_changes = self.state.previous_lines_changes

  for lnum = top, bot do
    if self.props.layout_type() == 'split' and previous_lines_changes and previous_lines_changes[lnum] then
      local component_type = 'previous'
      local line_changes = previous_lines_changes[lnum]

      self:render_line_diff(component_type, line_changes, lnum)
      self:render_word_diff(component_type, line_changes, lnum)
    end

    if current_lines_changes and current_lines_changes[lnum] then
      local component_type = 'current'
      local line_changes = current_lines_changes[lnum]

      self:render_line_diff(component_type, line_changes, lnum)
      self:render_word_diff(component_type, line_changes, lnum)
    end
  end
end

function DiffView:render_unified_conflicts(conflicts)
  local component = self.scene:get('current')

  utils.list.each(conflicts, function(conflict)

  end)
end

function DiffView:reset_cursor()
  if self.props.layout_type() == 'split' then self.scene:get('previous'):reset_cursor() end
  self.scene:get('current'):reset_cursor()
end

function DiffView:clear_title()
  local header_component = self.scene:get('header')
  if header_component then return header_component:clear_title() end

  if self.props.layout_type() == 'split' then
    self.scene:get('previous'):clear_title()
  else
    self.scene:get('current'):clear_title()
  end
end

function DiffView:clear_extmarks()
  if self.props.layout_type() == 'split' then self.scene:get('previous'):clear_extmarks() end

  self.scene:get('current'):clear_extmarks()

  local header_component = self.scene:get('header')
  if header_component then header_component:clear_extmarks() end
end

function DiffView:clear_lines()
  if self.props.layout_type() == 'split' then self.scene:get('previous'):clear_lines():disable_cursorline() end
  self.scene:get('current'):clear_lines():disable_cursorline()
end

function DiffView:clear_notification()
  local header_component = self.scene:get('header')
  if header_component then return header_component:clear_notification() end

  if self.props.layout_type() == 'split' then self.scene:get('previous'):clear_notification() end
  self.scene:get('current'):clear_notification()
end

function DiffView:render_title()
  local filepath = self.props.filepath()
  if not filepath then return end

  local filetype = self.props.filetype()
  if not filetype then return end

  local diff = self.props.diff()
  if not diff then return end

  local options = {
    filepath = filepath,
    filetype = filetype,
    stat = diff.stat,
  }

  local title = 'Diff'
  local header_component = self.scene:get('header')
  if header_component then return header_component:set_title(title, options) end

  if self.props.layout_type() == 'split' then return self.scene:get('previous'):set_title(title, options) end

  self.scene:get('current'):set_title(title, options)
end

function DiffView:render_filetype()
  local filetype = self.props.filetype()
  if not filetype then return end

  local current_component = self.scene:get('current')
  if current_component:get_filetype() == filetype then return end

  if self.props.layout_type() == 'split' then self.scene:get('previous'):set_filetype(filetype) end
  current_component:set_filetype(filetype)
end

function DiffView:render_split_current_line_numbers(diff, lnum_change_map)
  local padding = self:get_tabline_padding()
  local lines = {}
  local line_count = 1
  local lines_changes = {}
  local num_lines = #diff.current_lines

  -- Add padding entries
  for _ = 1, padding do
    lines[#lines + 1] = { '', 'GitLineNr' }
    lines_changes[#lines_changes + 1] = { line_number = '', lnum_change = nil }
  end

  for i = 1, num_lines do
    local line
    local lnum_change = lnum_change_map[i]

    if lnum_change and lnum_change.type == 'void' then
      line = string.rep(symbols_setting:get('void'), string.len(tostring(num_lines)))
      lines[#lines + 1] = { line, 'GitLineNr' }
    elseif lnum_change and lnum_change.type == 'add' then
      line = string.format('%s ', line_count)
      lines[#lines + 1] = { line, 'GitSignsAdd' }
      line_count = line_count + 1
    elseif lnum_change and lnum_change.type == 'remove' then
      line = string.format('%s ', line_count)
      lines[#lines + 1] = { line, 'GitSignsDelete' }
      line_count = line_count + 1
    else
      line = string.format('%s ', line_count)
      lines[#lines + 1] = { line, 'GitLineNr' }
      line_count = line_count + 1
    end

    lines_changes[#lines_changes + 1] = {
      line_number = line,
      lnum_change = lnum_change,
    }
  end

  self.state.current_lines_changes = lines_changes
  self.scene:get('current'):render_line_numbers(lines)
end

function DiffView:render_split_previous_line_numbers(diff, lnum_change_map)
  local padding = self:get_tabline_padding()
  local lines = {}
  local line_count = 1
  local lines_changes = {}
  local num_lines = #diff.previous_lines

  -- Add padding entries
  for _ = 1, padding do
    lines[#lines + 1] = { '', 'GitLineNr' }
    lines_changes[#lines_changes + 1] = { line_number = '', lnum_change = nil }
  end

  for i = 1, num_lines do
    local line
    local lnum_change = lnum_change_map[i]

    if lnum_change and lnum_change.type == 'void' then
      line = string.rep(symbols_setting:get('void'), string.len(tostring(num_lines)))
      lines[#lines + 1] = { line, 'GitLineNr' }
    elseif lnum_change and lnum_change.type == 'add' then
      line = string.format('%s ', line_count)
      lines[#lines + 1] = { line, 'GitSignsAdd' }
      line_count = line_count + 1
    elseif lnum_change and lnum_change.type == 'remove' then
      line = string.format('%s ', line_count)
      lines[#lines + 1] = { line, 'GitSignsDelete' }
      line_count = line_count + 1
    else
      line = string.format('%s ', line_count)
      lines[#lines + 1] = { line, 'GitLineNr' }
      line_count = line_count + 1
    end

    lines_changes[#lines_changes + 1] = {
      line_number = line,
      lnum_change = lnum_change,
    }
  end

  self.state.previous_lines_changes = lines_changes
  self.scene:get('previous'):render_line_numbers(lines)
end

function DiffView:render_split_line_numbers()
  local diff = self.props.diff()
  if not diff then return end

  local current_lnum_change_map = {}
  local previous_lnum_change_map = {}
  local num_lnum_changes = #diff.lnum_changes

  for i = 1, num_lnum_changes do
    local lnum_change = diff.lnum_changes[i]

    if lnum_change.buftype == 'current' then
      current_lnum_change_map[lnum_change.lnum] = lnum_change
    elseif lnum_change.buftype == 'previous' then
      previous_lnum_change_map[lnum_change.lnum] = lnum_change
    end
  end

  self:render_split_previous_line_numbers(diff, previous_lnum_change_map)
  self:render_split_current_line_numbers(diff, current_lnum_change_map)
end

function DiffView:render_unified_line_numbers()
  local diff = self.props.diff()
  if not diff then return end

  local padding = self:get_tabline_padding()
  local lines_changes = {}
  local lines = {}
  local line_count = 1
  local lnum_change_map = {}
  local num_lines = #diff.lines
  local num_lnum_changes = #diff.lnum_changes

  for i = 1, num_lnum_changes do
    local lnum_change = diff.lnum_changes[i]
    lnum_change_map[lnum_change.lnum] = lnum_change
  end

  -- Add padding entries
  for _ = 1, padding do
    lines[#lines + 1] = { '', 'GitLineNr' }
    lines_changes[#lines_changes + 1] = { line_number = '', lnum_change = nil }
  end

  for i = 1, num_lines do
    local line = ''
    local lnum_change = lnum_change_map[i]

    if lnum_change and lnum_change.type == 'remove' then
      line = '  '
      lines[#lines + 1] = { line, 'GitSignsDelete' }
    elseif lnum_change and lnum_change.type == 'add' then
      line = string.format('%s ', line_count)
      lines[#lines + 1] = { line, 'GitSignsAdd' }
      line_count = line_count + 1
    else
      line = string.format('%s ', line_count)
      lines[#lines + 1] = { line, 'GitLineNr' }
      line_count = line_count + 1
    end

    lines_changes[#lines_changes + 1] = {
      line_number = line,
      lnum_change = lnum_change,
    }
  end

  self.state.current_lines_changes = lines_changes
  self.scene:get('current'):render_line_numbers(lines)
end

function DiffView:render_line_numbers()
  local layout_type = self.props.layout_type()

  if layout_type == 'split' then
    self:render_split_line_numbers()
  elseif layout_type == 'unified' then
    self:render_unified_line_numbers()
  end
end

function DiffView:prepend_padding(lines)
  local padding = self:get_tabline_padding()
  if padding == 0 then return lines end

  local padded = {}
  for _ = 1, padding do
    padded[#padded + 1] = ''
  end
  for _, line in ipairs(lines) do
    padded[#padded + 1] = line
  end
  return padded
end

function DiffView:render_lines()
  local diff = self.props.diff()
  if not diff then return end

  if self.props.layout_type() == 'unified' then
    return self.scene:get('current'):set_lines(self:prepend_padding(diff.lines)):enable_cursorline()
  end

  self.scene:get('previous'):set_lines(self:prepend_padding(diff.previous_lines)):enable_cursorline()
  self.scene:get('current'):set_lines(self:prepend_padding(diff.current_lines)):enable_cursorline()
end

function DiffView:notify(msg)
  local layout_type = self.props.layout_type()
  local header_component = self.scene:get('header')

  if header_component then
    header_component:notify(msg)
    return
  end

  if layout_type == 'split' then return self.scene:get('previous'):notify(msg) end

  self.scene:get('current'):notify(msg)
end

function DiffView:get_current_mark_under_cursor()
  local diff = self.props.diff()
  if not diff then return end

  local padding = self:get_tabline_padding()
  local marks = diff.marks
  local lnum = self.scene:get('current'):get_lnum() - padding

  for i = 1, #marks do
    local mark = marks[i]
    if lnum >= mark.top and lnum <= mark.bot then return mark, i end
  end
end

function DiffView:get_hunk_under_cursor()
  local diff = self.props.diff()
  if not diff then return end

  local padding = self:get_tabline_padding()
  local selected
  local marks = diff.marks
  local hunks = diff.hunks
  local lnum = self.scene:get('current'):get_lnum() - padding

  for i = 1, #marks do
    local mark = marks[i]
    if lnum >= mark.top and lnum <= mark.bot then
      selected = i
      break
    end
  end

  if selected then return hunks[selected], selected end
end

-- Returns the actual file line number for the current cursor position.
-- For removed lines (which don't exist in the file), returns the closest
-- valid line number above.
function DiffView:get_file_lnum()
  local lines_changes = self.state.current_lines_changes
  if not lines_changes or #lines_changes == 0 then return nil end

  local lnum = self.scene:get('current'):get_lnum()
  if lnum > #lines_changes then lnum = #lines_changes end

  -- Search current line and above for a valid line number
  for i = lnum, 1, -1 do
    local entry = lines_changes[i]
    if entry and entry.line_number then
      local file_lnum = tonumber(entry.line_number:match('%d+'))
      if file_lnum then return file_lnum end
    end
  end

  return nil
end

-- Check if lnum is visible using saved or current viewport, return viewport info
local function check_visibility(component, lnum, saved_viewport)
  local viewport = saved_viewport
  local is_visible = false

  if viewport then
    -- Use saved viewport, just need window height
    component.window:call(function()
      local win_height = vim.fn.winheight(0)
      local botline = viewport.topline + win_height - 1
      is_visible = lnum >= viewport.topline and lnum <= botline
    end)
  else
    -- Capture current viewport
    component.window:call(function()
      local view = vim.fn.winsaveview()
      viewport = { topline = view.topline }
      local win_height = vim.fn.winheight(0)
      local botline = view.topline + win_height - 1
      is_visible = lnum >= view.topline and lnum <= botline
    end)
  end

  return viewport, is_visible
end

-- Move cursor to lnum while preserving scroll position
local function move_cursor_preserving_scroll(component, lnum, saved_topline)
  component.window:call(function()
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    vim.fn.winrestview({ topline = saved_topline })
  end)
end

function DiffView:set_lnum(lnum, position)
  local current = self.scene:get('current')
  local previous = self.props.layout_type() == 'split' and self.scene:get('previous') or nil

  -- For non-smart positioning, use simple path
  if position ~= 'smart' then
    if previous then previous:set_lnum(lnum):position_cursor(position) end
    current:set_lnum(lnum):position_cursor(position)
    return
  end

  -- Smart positioning: center only if target line is off-screen

  -- Determine visibility using saved viewport (from before render) or current
  local current_viewport, is_visible = check_visibility(
    current, lnum, self._saved_viewport
  )
  self._saved_viewport = nil

  local previous_viewport = nil
  if previous then
    previous_viewport = self._saved_viewport_previous or capture_viewport(previous)
    self._saved_viewport_previous = nil
  end

  -- If off-screen, just center both windows
  if not is_visible then
    if previous then previous:set_lnum(lnum):position_cursor('center') end
    current:set_lnum(lnum):position_cursor('center')
    return
  end

  -- Target is visible: move cursor without changing scroll position
  -- Disable scrollbind temporarily so windows don't interfere
  local had_scrollbind_current, had_scrollbind_previous
  current.window:call(function()
    had_scrollbind_current = vim.wo.scrollbind
    vim.wo.scrollbind = false
  end)
  if previous then
    previous.window:call(function()
      had_scrollbind_previous = vim.wo.scrollbind
      vim.wo.scrollbind = false
    end)
  end

  -- Move cursors while preserving scroll positions
  if previous and previous_viewport then
    move_cursor_preserving_scroll(previous, lnum, previous_viewport.topline)
  elseif previous then
    previous:set_lnum(lnum)
  end
  move_cursor_preserving_scroll(current, lnum, current_viewport.topline)

  -- Restore scrollbind
  if had_scrollbind_current then
    current.window:call(function() vim.wo.scrollbind = true end)
  end
  if had_scrollbind_previous and previous then
    previous.window:call(function() vim.wo.scrollbind = true end)
  end
end

function DiffView:set_relative_lnum(lnum, position)
  local diff = self.props.diff()
  if not diff then return end

  local padding = self:get_tabline_padding()

  for i = 1, #diff.lnum_changes do
    local lnum_change = diff.lnum_changes[i]
    local l = lnum_change.lnum
    local type = lnum_change.type
    local buftype = lnum_change.buftype

    if buftype == 'current' and (type == 'void' or type == 'remove') and lnum >= l then lnum = lnum + 1 end
  end

  self:set_lnum(lnum + padding, position)
end

-- Find the diff view line that corresponds to a source file line number
function DiffView:find_diff_line_for_source(source_lnum)
  local lines_changes = self.state.current_lines_changes
  if not lines_changes or #lines_changes == 0 then return nil end

  -- Search for a line with matching line_number
  for diff_lnum, entry in ipairs(lines_changes) do
    if entry and entry.line_number then
      local file_lnum = tonumber(entry.line_number:match('%d+'))
      if file_lnum and file_lnum == source_lnum then
        return diff_lnum
      end
    end
  end

  -- Source line not found directly - find nearest line before it
  local best_diff_lnum = nil
  local best_source_lnum = 0
  for diff_lnum, entry in ipairs(lines_changes) do
    if entry and entry.line_number then
      local file_lnum = tonumber(entry.line_number:match('%d+'))
      if file_lnum and file_lnum <= source_lnum and file_lnum > best_source_lnum then
        best_source_lnum = file_lnum
        best_diff_lnum = diff_lnum
      end
    end
  end

  return best_diff_lnum
end

-- Set cursor to the diff line corresponding to a source file line
-- source_winline: cursor's position relative to window top (from vim.fn.winline())
function DiffView:set_source_lnum(source_lnum, source_col, source_winline)
  local diff_lnum = self:find_diff_line_for_source(source_lnum)
  if diff_lnum then
    local component = self.scene:get('current')
    component:set_cursor({ diff_lnum, source_col and (source_col - 1) or 0 })
    -- Restore scroll position so cursor is at same relative position in window
    if source_winline then
      local win_id = component.window and component.window.win_id
      if win_id and vim.api.nvim_win_is_valid(win_id) then
        vim.api.nvim_win_call(win_id, function()
          local target_top = diff_lnum - source_winline + 1
          if target_top >= 1 then
            vim.fn.winrestview({ topline = target_top })
          end
        end)
      end
    end
  end
end

function DiffView:move_to_mark(marks, mark_index, position)
  local padding = self:get_tabline_padding()
  local lnum = nil
  local mark = marks[mark_index]

  if mark then lnum = mark.top end

  if not lnum then
    if marks and marks[#marks] and marks[#marks].top then
      lnum = marks[#marks].top
      mark_index = #marks
    else
      lnum = 1
      mark_index = 1
    end
  end

  -- Add padding offset to mark position
  self:set_lnum(lnum + padding, position)

  return mark
end

function DiffView:prev(pos)
  local diff = self.props.diff()
  if not diff then return end

  local padding = self:get_tabline_padding()
  local marks = diff.marks
  local lnum = self.scene:get('current'):get_lnum() - padding
  local mark_index = #marks

  for i = #marks, 1, -1 do
    local mark = marks[i]

    if lnum >= mark.top and lnum <= mark.bot then
      mark_index = i - 1
      break
    elseif mark.top < lnum then
      mark_index = i
      break
    end
  end

  return self:move_to_hunk(mark_index, pos)
end

function DiffView:next(pos)
  local diff = self.props.diff()
  if not diff then return end

  local padding = self:get_tabline_padding()
  local marks = diff.marks
  local lnum = self.scene:get('current'):get_lnum() - padding
  local mark_index = 1
  local num_marks = #marks

  for i = 1, num_marks do
    local mark = marks[i]

    if lnum >= mark.top and lnum <= mark.bot then
      mark_index = i + 1
      break
    elseif mark.top > lnum then
      mark_index = i
      break
    end
  end

  return self:move_to_hunk(mark_index, pos)
end

function DiffView:get_relative_mark_index(lnum)
  local diff = self.props.diff()
  if not diff then return 1 end

  local marks = diff.marks
  local mark_index = 1

  for i = 1, #marks do
    local mark = marks[i]

    if lnum >= mark.top_relative and lnum <= mark.bot_relative then
      mark_index = i
      break
    end
  end

  return mark_index
end

function DiffView:move_to_hunk(mark_index, pos)
  if not pos then pos = 'top' end

  if not mark_index then mark_index = 1 end

  local diff = self.props.diff()
  if not diff then return end

  local marks = diff.marks
  if #marks == 0 then return self:notify('No changes found') end

  if mark_index < 1 then
    mark_index = #marks
  elseif mark_index > #marks then
    mark_index = 1
  end

  self:move_to_mark(marks, mark_index, pos)

  local msg = string.format('%s%s/%s Changes', string.rep(' ', 1), mark_index, #marks)
  self:notify(msg)
end

function DiffView:mount()
  if self.props.layout_type() == 'split' then self.scene:get('previous'):mount() end

  self.scene:get('current'):mount()
  self.state = DiffView:get_initial_state()
end

-- Returns padding offset for tabline compensation
-- Diff needs 2 lines: 1 for tabline + 1 for HeaderElement
function DiffView:get_tabline_padding()
  if vim.o.showtabline > 0 then return 2 end
  return 0
end

function DiffView:render()
  local ok, msg = pcall(function()
    loop.free_textlock()
    self:clear_extmarks()

    local diff = self.props.diff()
    if not diff then
      self.state = DiffView:get_initial_state()

      self:clear_title()
      self:clear_lines()
      self:clear_notification()
      self:reset_cursor()

      return
    end

    self:reset_cursor()
    self:render_title()
    self:render_filetype()
    self:render_lines()
    self:render_line_numbers()
    self:render_diff()
  end)

  if not ok then console.debug.error(msg) end
end

return DiffView
