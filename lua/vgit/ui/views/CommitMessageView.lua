local Object = require('vgit.core.Object')
local dimensions = require('vgit.ui.dimensions')
local PresentationalComponent = require('vgit.ui.components.PresentationalComponent')

--[[
  The expanded commit's message, under the commit list. Its subject titles
  the box, which grows up from the bottom of the screen to fit the body, up
  to half the screen.

  props:
    message() - the message lines
    on_resize(row) - the box now starts at screen row `row`
]]

local CommitMessageView = Object:extend()

function CommitMessageView:constructor(scene, props, plot)
  return {
    scene = scene,
    plot = plot,
    props = props,
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

-- The width from the plot, not the window's current width
function CommitMessageView:get_configured_width()
  return self.plot.width and dimensions.convert(self.plot.width) or dimensions.convert('25vw')
end

-- Display height of `lines` once wrapped
function CommitMessageView:get_wrapped_height(lines)
  local width = self:get_configured_width()
  local height = 0
  for _, line in ipairs(lines) do
    local display_width = vim.fn.strdisplaywidth(line)
    height = height + math.max(1, math.ceil(display_width / width))
  end
  return height
end

-- Size the box to `height` rows, its header included, up to half the screen
function CommitMessageView:resize(height)
  local total_height = dimensions.convert('100vh')
  height = math.max(1, math.min(height, math.floor(total_height * 0.5)))
  if self.current_height == height then return end
  self.current_height = height

  local row = total_height - height
  local col = self.plot.col and dimensions.convert(self.plot.col) or 0
  local width = self:get_configured_width()
  local component = self.scene:get('commit_message')

  local header = component.elements.header
  if header and header.window:is_valid() then
    header.window:set_win_plot({ relative = 'editor', row = row, col = col, width = width, height = 1 })
  end

  -- A float must be at least 1 row, so with no body (header only) it would
  -- overflow the usable area. Hide it instead.
  local window = component.window
  if window:is_valid() then
    if height == 1 then
      window:set_win_plot({ hide = true })
    else
      window:set_win_plot({
        relative = 'editor',
        row = row + 1,
        col = col,
        width = width,
        height = height - 1,
        hide = false,
      })
    end
  end

  if self.props.on_resize then self.props.on_resize(row) end
end

-- Re-plot for the editor's current size: re-fit the box to its message,
-- placing it anew even at an unchanged height
function CommitMessageView:replot()
  self.current_height = nil
  self:render()
end

function CommitMessageView:render()
  local component = self.scene:get('commit_message')
  local message = self.props.message()
  component:set_title(message[1] and message[1] ~= '' and message[1] or 'Commit Message')

  -- The body follows the subject and the blank line after it
  local body = vim.list_slice(message, message[2] == '' and 3 or 2)
  while #body > 0 and body[#body] == '' do
    body[#body] = nil
  end

  if #body == 0 then
    self:resize(1)
    component:unlock():set_lines({ '' }):lock()
    return
  end

  -- The header row, then the wrapped body over a blank last line, which
  -- keeps the body's end above the command line
  self:resize(self:get_wrapped_height(body) + 1)
  body[#body + 1] = ''
  component:unlock():set_lines(body):lock()

  -- set_lines leaves the window scrolled wherever the previous, longer
  -- message left it, so pin the view to the top
  if component.window:is_valid() then component.window:set_cursor({ 1, 0 }) end
end

return CommitMessageView
