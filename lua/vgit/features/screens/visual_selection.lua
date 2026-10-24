--[[
  Shared helpers for visual-mode line operations on a rendered diff
  (line-level mark-seen in the review screens, line-level staging in the
  project diff screen).
]]

local visual_selection = {}

-- Selections for the hunks intersecting buffer lines [top, bot]: { index }
-- for a fully covered hunk, else partial(index, mark, lo, hi) for its
-- covered rows [lo, hi]. Nil when nothing intersects.
local function select_hunks(diff, top, bot, partial)
  if not diff or not diff.marks then return nil end

  local selections = {}
  for i, mark in ipairs(diff.marks) do
    local lo = math.max(mark.top, top)
    local hi = math.min(mark.bot, bot)
    if lo <= hi then
      if lo == mark.top and hi == mark.bot then
        selections[#selections + 1] = { index = i }
      else
        selections[#selections + 1] = partial(i, mark, lo, hi)
      end
    end
  end

  if #selections == 0 then return nil end
  return selections
end

-- Number of removed lines in diff's hunk `index`
local function removed_count(diff, index)
  local hunk = diff.hunks[index]
  return hunk and #(hunk:parse_diff()) or 0
end

-- Map a visual line range to per-hunk pair-row selections:
-- { index = hunk_index, rows = set-of-rows | nil }, rows == nil meaning the
-- whole hunk. Row r pairs removed line r with added line r, the way split
-- renders them side by side. In unified, which stacks a hunk's removed lines
-- above its added lines, both halves map onto the same pair row.
function visual_selection.for_range(diff, layout_type, top, bot)
  return select_hunks(diff, top, bot, function(index, mark, lo, hi)
    local removed = layout_type == 'unified' and removed_count(diff, index) or 0
    local rows = {}
    for lnum = lo, hi do
      local r = lnum - mark.top + 1
      rows[r > removed and r - removed or r] = true
    end
    return { index = index, rows = rows }
  end)
end

-- Map a visual line range in a unified diff to per-hunk line selections, as
-- precise as `git add -p` line editing: { index = hunk_index, lines = {
-- removed = set, added = set } }, sets of 1-based indices into the hunk's
-- removed and added lines. A whole hunk has no `lines`.
function visual_selection.lines_for_range(diff, top, bot)
  return select_hunks(diff, top, bot, function(index, mark, lo, hi)
    local removed = removed_count(diff, index)
    local lines = { removed = {}, added = {} }
    for lnum = lo, hi do
      local r = lnum - mark.top + 1
      if r > removed then
        lines.added[r - removed] = true
      else
        lines.removed[r] = true
      end
    end
    return { index = index, lines = lines }
  end)
end

-- Wrap a range consumer in a visual-mode keymap handler. The selection
-- endpoints must be read while still in visual mode, so they are captured
-- synchronously before leaving it. `run(top, bot)` may then defer (e.g. to a
-- job queue).
function visual_selection.make_handler(run)
  return function()
    local top = vim.fn.line('v')
    local bot = vim.fn.line('.')
    if top > bot then top, bot = bot, top end

    -- Leave visual mode before mutating state and re-rendering
    local esc = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
    vim.api.nvim_feedkeys(esc, 'nx', false)

    run(top, bot)
  end
end

return visual_selection
