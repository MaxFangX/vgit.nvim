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

-- How many context lines around a hunk participate in rebase matching.
local REBASE_CONTEXT = 3

-- Count matching context lines walking outward from a position:
-- direction -1 compares old_base[old_edge], new_base[new_edge] then one line
-- further out per step; direction 1 walks downward. Stops at the first
-- mismatch or array edge.
local function context_score(old_base, new_base, old_edge, new_edge, direction)
  local score = 0
  for i = 0, REBASE_CONTEXT - 1 do
    local old_line = old_base[old_edge + direction * i]
    local new_line = new_base[new_edge + direction * i]
    if old_line == nil or new_line == nil or old_line ~= new_line then break end
    score = score + 1
  end
  return score
end

local function block_matches(hay, pos, needle)
  if pos < 1 or pos + #needle - 1 > #hay then return false end
  for i = 1, #needle do
    if hay[pos + i - 1] ~= needle[i] then return false end
  end
  return true
end

-- Find where a hunk's old-side region lands in new_base. The region content
-- (removed lines) must match exactly; surrounding context breaks ties, then
-- proximity to the original position. min_pos enforces ordering against
-- previously matched hunks. Returns the matched position or nil.
--
-- For replacements/deletions (c > 0), position p means the region occupies
-- new_base[p .. p+c-1]. For pure insertions (c == 0), position q means
-- "insert after line q" and at least one context line must match — except
-- for an empty old_base, which only maps onto an equally empty new_base.
local function locate_region(old_base, new_base, s, c, removed, min_pos)
  local best_pos, best_score
  local function consider(pos, score)
    if best_score == nil or score > best_score
        or (score == best_score and math.abs(pos - s) < math.abs(best_pos - s)) then
      best_pos, best_score = pos, score
    end
  end

  if c > 0 then
    for p = math.max(1, min_pos), #new_base - c + 1 do
      if block_matches(new_base, p, removed) then
        local score = context_score(old_base, new_base, s - 1, p - 1, -1)
          + context_score(old_base, new_base, s + c, p + c, 1)
        consider(p, score)
      end
    end
    return best_pos
  end

  if #old_base == 0 then
    return #new_base == 0 and 0 or nil
  end

  for q = math.max(0, min_pos - 1), #new_base do
    local score = context_score(old_base, new_base, s, q, -1)
      + context_score(old_base, new_base, s + 1, q + 1, 1)
    if score > 0 then consider(q, score) end
  end
  return best_pos
end

-- Re-play diff(old_base -> approved) onto new_base: the index analog of a
-- rebase. Each hunk is located in new_base by content + context and applied
-- there; hunks whose region can't be found (the new base changed those very
-- lines) are dropped individually, reverting just their delta to unseen.
-- hunks must be in ascending old-side order (as git_hunks.live returns them).
-- Returns the rebased line array and the number of dropped hunks.
function hunk_apply.rebase(hunks, old_base, new_base)
  local matched = {}
  local dropped = 0
  local min_pos = 1

  for _, hunk in ipairs(hunks) do
    local previous = hunk:parse_header()
    local removed, added = hunk:parse_diff()
    local s, c = previous[1], previous[2]

    local pos = locate_region(old_base, new_base, s, c, removed, min_pos)
    if pos then
      matched[#matched + 1] = { pos = pos, count = c, added = added }
      min_pos = c > 0 and pos + c or pos + 1
    else
      dropped = dropped + 1
    end
  end

  local result = {}
  local cursor = 1
  for _, m in ipairs(matched) do
    -- For insertions (count == 0) content goes after line m.pos, so the copy
    -- includes it; for replacements it stops just before the region.
    local copy_until = m.count == 0 and m.pos or m.pos - 1
    for i = cursor, copy_until do
      result[#result + 1] = new_base[i]
    end
    for i = 1, #m.added do
      result[#result + 1] = m.added[i]
    end
    cursor = copy_until + m.count + 1
  end
  for i = cursor, #new_base do
    result[#result + 1] = new_base[i]
  end

  return result, dropped
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
