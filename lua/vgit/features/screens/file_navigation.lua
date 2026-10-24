-- Shared helpers for navigating between files, used by ProjectDiffScreen and
-- ProjectReviewScreen. `files` are list file nodes in display order (see
-- BaseListView:file_nodes), independent of which folds are open.

local M = {}

-- Whether J/K should cross into the adjacent file rather than jump to the
-- current file's last/first hunk. direction: 'next' (J) or 'prev' (K). True
-- with no hunks, or when the cursor is already on that hunk. From below the
-- last hunk, J lands on it first, and K likewise from above the first.
function M.should_cross_file(direction, current_index, total_hunks, position)
  if not current_index or total_hunks == 0 then return true end
  if position ~= 'inside' then return false end

  return current_index == (direction == 'next' and total_hunks or 1)
end

-- Whether two file nodes belong to the same commit row. A partly seen commit
-- has a row in both sections, so this compares the section as well as the
-- hash.
local function same_commit(a, b)
  return a.entry.commit_hash == b.entry.commit_hash and a.entry.type == b.entry.type
end

-- Target index for a J/K commit jump in the by-commit list: the next commit's
-- first file ('next') or the previous commit's last file ('prev'), wrapping.
-- Both are the file just past the current commit's edge in the direction of
-- travel.
function M.adjacent_commit_target(files, current_index, direction)
  local current = files[current_index]
  local total = #files
  local step = direction == 'next' and 1 or -1

  local edge = current_index
  while edge + step >= 1 and edge + step <= total and same_commit(files[edge + step], current) do
    edge = edge + step
  end

  return ((edge + step - 1) % total) + 1
end

-- Id of the first file after `id` (wrapping, `id` itself excluded) whose
-- entry has type `entry_type`, or nil
function M.next_of_type(files, id, entry_type)
  local start
  for i, node in ipairs(files) do
    if node.id == id then
      start = i
      break
    end
  end
  if not start then return nil end

  for offset = 1, #files - 1 do
    local node = files[(start - 1 + offset) % #files + 1]
    if node.entry.type == entry_type then return node.id end
  end
  return nil
end

-- After a mark/unmark rewrites a diff, pick the hunk to land on: the first
-- one past where the marked region began, or nil if none is. `from` is that
-- point: { top = new-side line (top_relative), old = old-side line }.
-- A partially marked hunk splits, and the remainder above the marked rows
-- keeps the original start line, so the new side compares strictly, to land
-- below the marked lines rather than pull the cursor back up. A pure
-- deletion has no new-side lines, so whatever is left of one starts at the
-- same new-side line; it is past the marked region if its old side reaches
-- the region's start.
function M.hunk_past_position(diff, from)
  for i, mark in ipairs(diff.marks) do
    if mark.top_relative > from.top then return i end

    local previous, current = diff.hunks[i]:parse_header()
    if mark.top_relative == from.top and current[2] == 0 and previous[1] + previous[2] > from.old then return i end
  end
  return nil
end

local function to_ref(node)
  return { filepath = node.entry.status.filepath }
end

-- Find next/prev/first files among `files` matching `predicate(node)`,
-- relative to the file at `current_filepath`. Each return value is
-- { filepath } or nil; first_file (the first match) is for wrap-around.
function M.find_adjacent_files(files, current_filepath, predicate)
  local next_file, prev_file, first_file = nil, nil, nil
  local found_current = false

  for _, node in ipairs(files) do
    if predicate(node) then
      first_file = first_file or to_ref(node)

      if found_current then
        next_file = to_ref(node)
        break
      elseif node.entry.status.filepath == current_filepath then
        found_current = true
      else
        prev_file = to_ref(node)
      end
    end
  end

  return next_file, prev_file, first_file
end

return M
