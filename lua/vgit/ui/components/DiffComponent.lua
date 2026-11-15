local utils = require('vgit.core.utils')
local Window = require('vgit.core.Window')
local Buffer = require('vgit.core.Buffer')
local Component = require('vgit.ui.Component')
local HeaderTitle = require('vgit.ui.decorations.HeaderTitle')
local HeaderElement = require('vgit.ui.elements.HeaderElement')
local FooterElement = require('vgit.ui.elements.FooterElement')
local Notification = require('vgit.ui.decorations.Notification')

local DiffComponent = Component:extend()

function DiffComponent:constructor(props)
  props = utils.object.assign({
    config = {
      elements = {
        header = true,
        footer = true,
      },
      win_plot = {
        zindex = 3,
      },
    },
  }, props)
  return Component.constructor(self, props)
end

function DiffComponent:set_cursor(cursor)
  self.window:set_cursor(cursor)
  return self
end

function DiffComponent:set_lnum(lnum)
  self.window:set_lnum(lnum)
  return self
end

function DiffComponent:call(callback)
  self.window:call(callback)
  return self
end

function DiffComponent:reset_cursor()
  Component.reset_cursor(self)
  return self
end

function DiffComponent:clear_lines()
  Component.clear_lines(self)
  return self
end

function DiffComponent:position_cursor(placement)
  Component.position_cursor(self, placement)
  return self
end

-- Wrap long lines, at word boundaries, or cut them off at the window's edge
function DiffComponent:set_wrap(wrap)
  self.window:assign_options({ wrap = wrap, linebreak = wrap })
  return self
end

-- The screen rows that 0-based `row` takes up in the window
function DiffComponent:get_row_height(row)
  return vim.api.nvim_win_text_height(self.window.win_id, { start_row = row, end_row = row }).all
end

-- The cells of a screen row that hold text. A wrapped line's later rows lose
-- as many to 'showbreak' as its first does to the line number.
function DiffComponent:get_text_width()
  local win_id = self.window.win_id
  return self.window:get_width() - vim.fn.getwininfo(win_id)[1].textoff - #vim.wo[win_id].showbreak
end

-- Make wrapped 0-based `row` `count` screen rows taller, by ending its line
-- with that many rows of `fill` characters. Filler lines would do, but
-- 'scrollbind' counts them as lines, so the split panes would drift apart.
function DiffComponent:pad_row(row, count, fill, hl)
  local line = self.buffer:get_lines(row, row + 1)[1]
  -- The fill completes the line's last screen row, which an empty line lacks
  if line == '' then count = count + 1 end

  self:place_extmark_padding({
    row = row,
    col = #line,
    pos = 'inline',
    text = string.rep(fill, count * self:get_text_width()),
    hl = hl,
  })
  return self
end

function DiffComponent:mount(opts)
  opts = opts or {}

  if self.mounted then return self end

  local config = self.config

  self.notification = Notification()
  self.header_title = HeaderTitle()
  self.buffer = Buffer():create():assign_options(config.buf_options)

  local plot = self.plot
  local buffer = self.buffer

  if config.elements.header then self.elements.header = HeaderElement():mount(plot.header_win_plot) end
  if config.elements.footer then self.elements.footer = FooterElement():mount(plot.footer_win_plot) end

  self.window = Window:open(buffer, plot.win_plot):assign_options(config.win_options)

  -- Enforce minimum scrolloff of 2 to account for floating header
  local global_scrolloff = vim.o.scrolloff
  if global_scrolloff < 2 then
    self.window:set_option('scrolloff', 2)
  end

  self.mounted = true

  return self
end

function DiffComponent:unmount()
  if not self.mounted then return self end

  local header = self.elements.header
  local footer = self.elements.footer

  self.window:close()
  if header then header:unmount() end
  if footer then footer:unmount() end

  return self
end

function DiffComponent:set_title(title, opts)
  local header = self.elements.header
  if not header then return self end

  self.header_title:set(header, title, opts)

  return self
end

function DiffComponent:clear_title()
  local header = self.elements.header
  if not header then return self end

  self.header_title:clear(header)

  return self
end

function DiffComponent:render_line_numbers(lines)
  local offset = 1
  local max_digits = string.len(tostring(#lines)) + offset

  -- A wrapped line continues under its text, not under its number
  self.window:set_option('showbreak', string.rep(' ', max_digits))

  for i = 1, #lines do
    local hl = lines[i][2]
    local text = lines[i][1]
    local text_len = string.len(text)
    if text_len < max_digits then text = string.format('%s%s', string.rep(' ', max_digits - text_len), text) end
    self:place_extmark_lnum({
      row = i - 1,
      hl = hl,
      text = text,
    })
  end

  return self
end

function DiffComponent:clear_extmarks()
  Component.clear_extmarks(self)

  local header = self.elements.header
  if header then header:clear_extmarks() end

  return self
end

function DiffComponent:clear_notification()
  local header = self.elements.header
  if not header then return self end

  self.notification:clear_notification(header)

  return self
end

function DiffComponent:notify(text)
  local header = self.elements.header
  if not header then return self end

  self.notification:notify(header, text)

  return self
end

return DiffComponent
