--[[
  hunk_apply applies GitHunks (produced by diffing two in-memory contents,
  e.g. git_hunks.live) onto line arrays. This is the patch engine behind the
  review screens: marking hunks/lines "seen" advances the approved
  snapshot by applying hunks of diff(approved -> current); unmarking rolls it
  back by reverse-applying hunks of diff(base -> approved).

  A selection picks part of a hunk in one of two ways:

  - rows (a set of row indices): row r of a hunk pairs removed[r] with
    added[r], as the split layout renders them side by side. A selected row
    takes the new side (its added line, or nothing for a deletion); an
    unselected row keeps the old side.
  - lines ({ removed = set, added = set } of indices into the hunk's removed
    and added lines), like `git add -p` line selection, for the unified
    layout: selected removed lines go, unselected ones stay, then selected
    added lines come in after them.

  Reversing applies the inverted hunk, so a selection picks the lines to
  revert.
]]

local GitHunk = require('vgit.git.GitHunk')

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

-- The lines that replace a hunk's old side once `pick` is applied: nil for
-- the whole hunk, or a selection's { rows } or { lines } (see the header).
local function picked_region(removed, added, pick)
  local region = {}
  if pick and pick.lines then
    for r, line in ipairs(removed) do
      if not pick.lines.removed[r] then region[#region + 1] = line end
    end
    for a, line in ipairs(added) do
      if pick.lines.added[a] then region[#region + 1] = line end
    end
    return region
  end

  local rows = pick and pick.rows
  for r = 1, math.max(#removed, #added) do
    if rows == nil or rows[r] then
      region[#region + 1] = added[r]
    else
      region[#region + 1] = removed[r]
    end
  end
  return region
end

-- The pick for a hunk's inversion: rows pair up the same way, and lines swap
-- sides.
local function inverted_pick(pick)
  if not (pick and pick.lines) then return pick end
  return { lines = { removed = pick.lines.added, added = pick.lines.removed } }
end

-- Splice a hunk's region into lines: copy [1, pos), the region, then the
-- tail after the replaced range. When count == 0 the header start is the
-- line the change goes *after* (git convention), so nothing is replaced.
local function splice(lines, start, count, region)
  local pos = count == 0 and start + 1 or start
  local result = {}

  for i = 1, pos - 1 do
    result[#result + 1] = lines[i]
  end
  for _, line in ipairs(region) do
    result[#result + 1] = line
  end
  for i = pos + count, #lines do
    result[#result + 1] = lines[i]
  end

  return result
end

-- Apply a hunk of diff(old -> new) onto old_lines (moves content toward new).
-- pick: a selection's { rows } or { lines } (see the header); nil applies
-- the whole hunk. Returns a new line array.
function hunk_apply.apply(old_lines, hunk, pick)
  local removed, added = hunk:parse_diff()
  local previous = hunk:parse_header()
  return splice(old_lines, previous[1], previous[2], picked_region(removed, added, pick))
end

-- Reverse-apply a hunk of diff(old -> new) onto new_lines (moves content back
-- toward old). The picked rows or lines are reverted.
function hunk_apply.reverse(new_lines, hunk, pick)
  local removed, added = hunk:parse_diff()
  local _, current = hunk:parse_header()
  return splice(new_lines, current[1], current[2], picked_region(added, removed, inverted_pick(pick)))
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
-- An insertion whose lines new_base already has between its context (say it
-- was squashed into the parent) matches as applied, the second return value.
local function locate_region(old_base, new_base, s, c, removed, added, min_pos)
  local best_pos, best_score, best_applied
  local function consider(pos, score, applied)
    if best_score == nil or score > best_score
        or (score == best_score and math.abs(pos - s) < math.abs(best_pos - s)) then
      best_pos, best_score, best_applied = pos, score, applied
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
    local above = context_score(old_base, new_base, s, q, -1)
    local score = above + context_score(old_base, new_base, s + 1, q + 1, 1)
    if score > 0 then consider(q, score, false) end

    -- Considered after the plain insertion at q, so it wins only on more context
    if block_matches(new_base, q + 1, added) then
      local applied_score = above + context_score(old_base, new_base, s + 1, q + #added + 1, 1)
      if applied_score > score then consider(q, applied_score, true) end
    end
  end
  return best_pos, best_applied
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

    local pos, applied = locate_region(old_base, new_base, s, c, removed, added, min_pos)
    -- An applied insertion keeps new_base's copy: insert nothing after it
    if applied then pos, added = pos + #added, {} end
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
-- { hunk = GitHunk, rows = set|nil, lines = { removed, added }|nil }, with
-- neither set for the whole hunk. Hunk header positions all reference the
-- same original lines, so selections are applied bottom-up to keep earlier
-- positions valid. direction: 'apply' or 'reverse'.
function hunk_apply.apply_selections(lines, selections, direction)
  local sorted = vim.list_slice(selections)
  table.sort(sorted, function(a, b)
    return a.hunk.top > b.hunk.top
  end)

  local op = direction == 'reverse' and hunk_apply.reverse or hunk_apply.apply
  for _, selection in ipairs(sorted) do
    lines = op(lines, selection.hunk, selection)
  end

  return lines
end

-- Append the hunk turning `removed`, which follows old line old_before, into
-- `added`, which follows new line new_before
local function push_hunk(result, old_before, removed, new_before, added)
  local old_start = old_before + (#removed > 0 and 1 or 0)
  local new_start = new_before + (#added > 0 and 1 or 0)
  local hunk = GitHunk({ { old_start, #removed }, { new_start, #added } })
  for _, line in ipairs(removed) do
    hunk:push('-' .. line)
  end
  for _, line in ipairs(added) do
    hunk:push('+' .. line)
  end
  result[#result + 1] = hunk
end

-- The rest of a hunk once rows are applied (rows == nil: all of them). A
-- selected row with an added line becomes context (both sides now agree),
-- splitting the hunk there; a selected pure deletion just vanishes from both
-- sides. Each run of unselected rows between such context lines becomes a
-- hunk of its own. Returns how many old' lines the hunk's region holds.
local function remaining_rows(result, removed, added, rows, old_before, new_before)
  -- old' lines emitted so far for this hunk's rows
  local emitted = 0

  -- The open run: its first row, and the old' line it follows
  local run_lo, run_old_before
  local function close_run(hi)
    if not run_lo then return end

    local sub_removed = {}
    for r = run_lo, math.min(hi, #removed) do
      if not (rows and rows[r]) then sub_removed[#sub_removed + 1] = removed[r] end
    end
    local sub_added = vim.list_slice(added, run_lo, math.min(hi, #added))
    -- A run past the added lines follows the last of them
    local sub_new_before = #sub_added > 0 and new_before + run_lo - 1 or new_before + #added
    push_hunk(result, run_old_before, sub_removed, sub_new_before, sub_added)

    emitted = emitted + #sub_removed
    run_lo = nil
  end

  for r = 1, math.max(#removed, #added) do
    if not (rows == nil or rows[r]) then
      if not run_lo then run_lo, run_old_before = r, old_before + emitted end
    elseif added[r] then
      close_run(r - 1)
      emitted = emitted + 1
    end
  end
  close_run(math.max(#removed, #added))

  return emitted
end

-- The rest of a hunk once a line selection is applied. Its old' region is
-- the unselected removed lines, then the selected added lines, which become
-- context where they sit among the added lines, splitting the hunk there.
-- Returns how many old' lines the hunk's region holds.
local function remaining_lines(result, removed, added, lines, old_before, new_before)
  local kept = {}
  for r, line in ipairs(removed) do
    if not lines.removed[r] then kept[#kept + 1] = line end
  end

  -- The open run: the old' line it follows, its removed lines (only the
  -- first run has any), and its first added line
  local run_old_before, run_removed, run_lo = old_before, kept, 1
  local picked = 0
  for a = 1, #added + 1 do
    if a > #added or lines.added[a] then
      if #run_removed > 0 or a > run_lo then
        push_hunk(result, run_old_before, run_removed, new_before + run_lo - 1, vim.list_slice(added, run_lo, a - 1))
      end
      -- Past the run's removed lines and the context line ending it
      run_old_before = run_old_before + #run_removed + 1
      run_removed, run_lo = {}, a + 1
      if a <= #added then picked = picked + 1 end
    end
  end

  return #kept + picked
end

-- Hunks of diff(old' -> new) once selections are applied onto old. picks[i]
-- is the selection of hunks[i] (see apply_selections), or false when
-- unselected.
local function remaining_applied(hunks, picks)
  local result = {}
  -- Net line shift of old' relative to old, from hunks already walked
  local delta = 0

  for i, hunk in ipairs(hunks) do
    local pick = picks[i]
    local previous, current = hunk:parse_header()

    if not pick then
      local shifted = GitHunk({ { previous[1] + delta, previous[2] }, current })
      for _, line in ipairs(hunk.diff) do
        shifted:push(line)
      end
      result[#result + 1] = shifted
    else
      local removed, added = hunk:parse_diff()
      -- The line preceding the hunk on each side (a zero-count header already
      -- names that line); old'-side starts also carry the running delta.
      local old_before = (previous[2] == 0 and previous[1] or previous[1] - 1) + delta
      local new_before = current[2] == 0 and current[1] or current[1] - 1

      local emitted
      if pick.lines then
        emitted = remaining_lines(result, removed, added, pick.lines, old_before, new_before)
      else
        emitted = remaining_rows(result, removed, added, pick.rows, old_before, new_before)
      end
      delta = delta + emitted - #removed
    end
  end

  return result
end

local function invert_all(hunks)
  return vim.tbl_map(function(hunk) return hunk:invert() end, hunks)
end

-- The diff left over after apply_selections: diff(old' -> new) for 'apply',
-- diff(old -> new') for 'reverse'. Derived from the existing hunks rather
-- than re-diffed, so marked lines stay where they were marked: a fresh diff
-- may align repeated content (say a closing `'';` / `};` pair) with a
-- different copy and show the mark on the wrong instance.
function hunk_apply.remaining(hunks, selections, direction)
  local picks_by_hunk = {}
  for _, selection in ipairs(selections) do
    picks_by_hunk[selection.hunk] = direction == 'reverse' and inverted_pick(selection) or selection
  end

  local picks = {}
  for i, hunk in ipairs(hunks) do
    picks[i] = picks_by_hunk[hunk] or false
  end

  if direction == 'reverse' then
    return invert_all(remaining_applied(invert_all(hunks), picks))
  end
  return remaining_applied(hunks, picks)
end

return hunk_apply
