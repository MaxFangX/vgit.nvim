--[[
  Shared helpers for visual-mode line operations on a rendered diff
  (line-level mark-seen in the indexed review screens, line-level staging in
  the project diff screen).
]]

local visual_selection = {}

-- Map a visual line range in a rendered diff buffer to per-hunk row
-- selections. Rows pair removed/added lines the way both layouts render them
-- side by side / stacked. Returns an array of { index = hunk_index,
-- rows = set-of-rows | nil } for hunks intersecting buffer lines [top, bot];
-- rows == nil means the whole hunk is covered. Returns nil when nothing
-- intersects.
function visual_selection.for_range(diff, layout_type, top, bot)
  if not diff or not diff.marks or #diff.marks == 0 then return nil end

  local selections = {}

  for i, mark in ipairs(diff.marks) do
    local lo = math.max(mark.top, top)
    local hi = math.min(mark.bot, bot)
    if lo <= hi then
      if lo == mark.top and hi == mark.bot then
        -- Whole hunk covered
        selections[#selections + 1] = { index = i, rows = nil }
      else
        local hunk = diff.hunks[i]
        local removed = hunk and select(1, hunk:parse_diff()) or {}
        local rows = {}
        for lnum = lo, hi do
          local r = lnum - mark.top + 1
          -- Unified renders a change hunk as all removed lines then all added
          -- lines; both halves collapse onto the same pair row. Split renders
          -- pair rows directly.
          if layout_type == 'unified' and r > #removed then
            rows[r - #removed] = true
          else
            rows[r] = true
          end
        end
        selections[#selections + 1] = { index = i, rows = rows }
      end
    end
  end

  if #selections == 0 then return nil end
  return selections
end

-- Wrap a range consumer in a visual-mode keymap handler. The selection
-- endpoints must be read while still in visual mode, so they are captured
-- synchronously before leaving visual mode; `run(top, bot)` may then defer
-- (e.g. to a debounced coroutine).
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
