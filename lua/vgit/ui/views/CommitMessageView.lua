local Object = require('vgit.core.Object')
local dimensions = require('vgit.ui.dimensions')
local PresentationalComponent = require('vgit.ui.components.PresentationalComponent')

local CommitMessageView = Object:extend()

function CommitMessageView:constructor(scene, props, plot, config)
  config = config or {}
  return {
    scene = scene,
    plot = plot,
    props = props,
    min_height = config.min_height or 1,
    current_height = nil,
  }
end

function CommitMessageView:get_components()
  return { self.scene:get('commit_message') }
end

function CommitMessageView:define()
  self.scene:set(
    'commit_message',
    PresentationalComponent({
      config = {
        elements = {
          header = true,
          footer = false,
        },
        win_options = {
          wrap = true,
          cursorline = false,
        },
        win_plot = dimensions.relative_win_plot(self.plot, {
          height = '100vh',
          width = '100vw',
        }),
      },
    })
  )
end

function CommitMessageView:mount()
  self.scene:get('commit_message'):mount()
end

-- Configured width from plot (stable, not runtime state)
function CommitMessageView:get_configured_width()
  return self.plot.width and dimensions.convert(self.plot.width) or dimensions.convert('25vw')
end

-- Calculate display height accounting for word wrap
function CommitMessageView:get_wrapped_height(lines)
  local width = self:get_configured_width()
  local height = 0
  for _, line in ipairs(lines) do
    local display_width = vim.fn.strdisplaywidth(line)
    height = height + math.max(1, math.ceil(display_width / width))
  end
  return height
end

-- Padding for header element (which floats over content)
function CommitMessageView:get_padding()
  if vim.o.showtabline > 0 then return 1 end
  return 0
end

function CommitMessageView:prepend_padding(lines)
  local padding = self:get_padding()
  local padded = {}
  for _ = 1, padding do
    padded[#padded + 1] = ''
  end
  for _, line in ipairs(lines) do
    padded[#padded + 1] = line
  end
  return padded
end

function CommitMessageView:resize(body_line_count)
  local total_height = dimensions.convert('100vh')
  local max_height = math.floor(total_height * 0.5)

  local target_height
  if body_line_count == 0 then
    -- No description: minimal height (just header)
    target_height = self.min_height
  else
    -- Has description: expand to fit content
    local padding = self:get_padding()
    local needed = padding + body_line_count
    target_height = math.max(self.min_height, math.min(needed, max_height))
  end

  if self.current_height == target_height then return end
  self.current_height = target_height

  local list_height = total_height - target_height
  local msg_row = list_height

  -- Get column and width from original plot
  local msg_col = self.plot.col and dimensions.convert(self.plot.col) or 0
  local msg_width = self.plot.width and dimensions.convert(self.plot.width) or dimensions.convert('25vw')

  local component = self.scene:get('commit_message')
  if not component then return end

  -- Resize and reposition main window
  if component.window and component.window.win_id then
    local win_id = component.window.win_id
    if vim.api.nvim_win_is_valid(win_id) then
      vim.api.nvim_win_set_config(win_id, {
        relative = 'editor',
        row = msg_row,
        col = msg_col,
        width = msg_width,
        height = target_height,
      })
    end
  end

  -- Reposition header element window
  if component.elements and component.elements.header and component.elements.header.window then
    local header_win_id = component.elements.header.window.win_id
    if header_win_id and vim.api.nvim_win_is_valid(header_win_id) then
      vim.api.nvim_win_set_config(header_win_id, {
        relative = 'editor',
        row = msg_row,
        col = msg_col,
        width = msg_width,
        height = 1,
      })
    end
  end

  -- Resize list window
  local list_view = self.props.list_view and self.props.list_view()
  if list_view then
    local list_component = list_view.scene:get('list')
    if list_component and list_component.window and list_component.window.win_id then
      local win_id = list_component.window.win_id
      if vim.api.nvim_win_is_valid(win_id) then
        vim.api.nvim_win_set_height(win_id, list_height)
      end
    end
  end
end

function CommitMessageView:render()
  local component = self.scene:get('commit_message')
  local message = self.props.message()

  -- Use commit title as header instead of "Commit Message"
  local title = (message and #message > 0 and message[1] ~= '') and message[1] or 'Commit Message'
  component:set_title(title)

  if not message or #message == 0 then
    self:resize(0)
    component:unlock():set_lines({ '' }):lock()
    return
  end

  -- Show body (skip title and empty line after it)
  local body = {}
  local start_idx = 2
  -- Skip empty line after title if present
  if message[2] and message[2] == '' then
    start_idx = 3
  end
  for i = start_idx, #message do
    body[#body + 1] = message[i]
  end

  -- Count non-empty lines to determine if there's actual content
  local content_line_count = 0
  for _, line in ipairs(body) do
    if line ~= '' then
      content_line_count = content_line_count + 1
    end
  end

  if content_line_count == 0 then
    self:resize(0)
    component:unlock():set_lines({ '' }):lock()
  else
    -- Strip trailing empty lines for height calculation
    local line_count = #body
    while line_count > 0 and body[line_count] == '' do
      line_count = line_count - 1
    end

    -- Calculate wrapped display height from configured width
    local display_lines = {}
    for i = 1, line_count do
      display_lines[i] = body[i]
    end
    self:resize(self:get_wrapped_height(display_lines))
    component:unlock():set_lines(self:prepend_padding(body)):lock()
  end
end

function CommitMessageView:clear()
  local component = self.scene:get('commit_message')
  component:unlock():set_lines({ '' }):lock()
end

return CommitMessageView
