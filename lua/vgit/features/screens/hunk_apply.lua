--[[
  hunk_apply applies GitHunks (produced by diffing two in-memory contents,
  e.g. git_hunks.live) onto line arrays. This is the patch engine behind the
  indexed review screens: marking hunks/lines "seen" advances the approved
  snapshot by applying hunks of diff(approved -> current); unmarking rolls it
  back by reverse-applying hunks of diff(base -> approved).

  Partial application uses row pairing: row r of a hunk pairs removed[r] with
  added[r] (the same pairing both diff layouts render side by side / stacked).
  A selected row takes the new side (added line, or nothing for a deletion);
  an unselected row keeps the old side. This mirrors `git add -p` line
  selection with stable ordering for mixed change hunks.
]]

local hunk_apply = {}

-- Shallow line-array equality
function hunk_apply.lines_equal(a, b)
  if a == b then return true end
  if not a or not b or #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

-- Emit the hunk's row-paired output into result.
-- rows == nil means every row is selected (full application).
local function emit_rows(result, old_side, new_side, rows)
  for r = 1, math.max(#old_side, #new_side) do
    if rows == nil or rows[r] then
      result[#result + 1] = new_side[r]
    else
      result[#result + 1] = old_side[r]
    end
  end
end

-- Splice a hunk's output into lines: copy [1, pos), emit rows, copy the tail
-- after the replaced range. When count == 0 the header start is the line the
-- change goes *after* (git convention), so nothing is replaced.
local function splice(lines, start, count, old_side, new_side, rows)
  local pos = count == 0 and start + 1 or start
  local result = {}

  for i = 1, pos - 1 do
    result[#result + 1] = lines[i]
  end
  emit_rows(result, old_side, new_side, rows)
  for i = pos + count, #lines do
    result[#result + 1] = lines[i]
  end

  return result
end

-- Apply a hunk of diff(old -> new) onto old_lines (moves content toward new).
-- rows: optional set of selected row indices (1-based within the hunk);
-- nil applies the whole hunk. Returns a new line array.
function hunk_apply.apply(old_lines, hunk, rows)
  local removed, added = hunk:parse_diff()
  local previous = hunk:parse_header()
  return splice(old_lines, previous[1], previous[2], removed, added, rows)
end

-- Reverse-apply a hunk of diff(old -> new) onto new_lines (moves content back
-- toward old). rows semantics match apply: selected rows are reverted.
function hunk_apply.reverse(new_lines, hunk, rows)
  local removed, added = hunk:parse_diff()
  local _, current = hunk:parse_header()
  return splice(new_lines, current[1], current[2], added, removed, rows)
end

-- Apply several selections in one pass. Each selection is
-- { hunk = GitHunk, rows = set|nil }. Hunk header positions all reference the
-- same original lines, so selections are applied bottom-up to keep earlier
-- positions valid. direction: 'apply' or 'reverse'.
function hunk_apply.apply_selections(lines, selections, direction)
  local sorted = {}
  for i = 1, #selections do
    sorted[i] = selections[i]
  end
  table.sort(sorted, function(a, b)
    return a.hunk.top > b.hunk.top
  end)

  local op = direction == 'reverse' and hunk_apply.reverse or hunk_apply.apply
  for _, selection in ipairs(sorted) do
    lines = op(lines, selection.hunk, selection.rows)
  end

  return lines
end

return hunk_apply
