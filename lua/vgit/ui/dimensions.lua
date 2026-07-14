local utils = require('vgit.core.utils')

local dimensions = {}

function dimensions.global_width()
  return vim.o.columns
end

-- Height usable by floating windows: floats may cover the statusline but are
-- shifted up (hiding their first rows under other floats) if they extend into
-- the command line or the tabline row. Only count the tabline when it's
-- actually drawn (showtabline=1 draws it only with multiple tab pages).
function dimensions.global_height()
  local tabline_height = 0
  if vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1) then
    tabline_height = 1
  end
  return vim.o.lines - vim.o.cmdheight - tabline_height
end

-- Express a fixed `cols`-wide list column as vw percentage strings
-- (list_pct, rest_pct) so fixed widths can flow through the relative plot
-- math, which assumes col + width add up to 100vw. The 0.1 nudge makes
-- convert()'s math.ceil land exactly on cols (and total - cols) instead of
-- one column past. Also returns the clamped column count.
function dimensions.fixed_split(cols)
  local total = dimensions.global_width()
  cols = math.max(20, math.min(cols, math.max(20, total - 40)))

  local list_pct = (cols - 0.1) * 100 / total
  local rest_pct = (total - cols - 0.1) * 100 / total

  return list_pct .. 'vw', rest_pct .. 'vw', cols
end

function dimensions.vh(value)
  return string.format('%svh', value)
end

function dimensions.vw(value)
  return string.format('%svw', value)
end

function dimensions.get_value(size)
  return tonumber(size:sub(1, #size - 2))
end

function dimensions.get_unit(size)
  return size:sub(#size - 1, #size)
end

function dimensions.relative_size(parent, child, op)
  if not child then return parent end

  if not parent then return child end

  -- TODO: Can relativity be applied on integers?
  if type(child) == 'number' then return child end
  -- TODO: Can relativity be applied on integers?
  if type(parent) == 'number' then return parent end

  local parent_value = dimensions.get_value(parent)
  local child_value = dimensions.get_value(child)

  if parent_value == 0 then return child end

  local ratio = child_value / 100
  if ratio == 0 then return parent end

  local value = ratio * parent_value
  local unit = dimensions.get_unit(parent)

  if op == 'add' then value = child_value + value end
  if op == 'remove' then value = child_value - value end

  return string.format('%s%s', value, unit)
end

-- Get dimension of child in relation to parent.
function dimensions.relative_win_plot(parent, child)
  parent = parent or {}
  child = child or {}

  return {
    relative = child.relative or parent.relative,
    height = dimensions.relative_size(parent.height, child.height),
    width = dimensions.relative_size(parent.width, child.width),
    row = dimensions.relative_size(parent.row, child.row, 'add'),
    col = dimensions.relative_size(parent.col, child.col, 'add'),
    zindex = child.zindex,
  }
end

function dimensions.convert(value)
  if type(value) == 'string' then
    local number_value = value:sub(1, #value - 2)
    local type = value:sub(#value - 1, #value)

    if type == 'vh' then return math.ceil((tonumber(number_value) / 100) * dimensions.global_height()) end
    if type == 'vw' then return math.ceil((tonumber(number_value) / 100) * dimensions.global_width()) end

    error(debug.traceback('error :: invalid dimension, should either be \'vh\' or \'vw\''))
  end

  return value
end

return dimensions
