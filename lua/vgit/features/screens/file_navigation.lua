-- Shared helpers for navigating between files, used by ProjectDiffScreen and
-- ProjectReviewScreen. `files` are list file nodes in display order (see
-- BaseListView:file_nodes), independent of which folds are open.

local M = {}

-- Whether J/K should cross into the adjacent file rather than jump to the
-- current file's last/first hunk. direction: 'next' (J) or 'prev' (K). True
-- with no hunks, or when the cursor is already on that hunk; from below the
-- last (above the first) hunk, J (K) lands on it first.
function M.should_cross_file(direction, current_index, total_hunks, position)
  if not current_index or total_hunks == 0 then return true end
  if position ~= 'inside' then return false end

  return current_index == (direction == 'next' and total_hunks or 1)
end

-- Whether two file nodes belong to the same commit row. Compares the section
-- as well as the hash: a partly seen commit has a row in both.
local function same_commit(a, b)
  return a.entry.commit_hash == b.entry.commit_hash and a.entry.type == b.entry.type
end

-- Target index for a J/K commit jump in the by-commit list: always leave the
-- current commit, landing on the next commit's first file ('next') or the
-- previous commit's last file ('prev'). Both are simply the file just past the
-- current commit's boundary, so one step off that edge lands correctly. Wraps
-- around. Files within a commit stay j/k's job.
function M.adjacent_commit_target(files, current_index, direction)
  local current = files[current_index]
  local total = #files
  local step = direction == 'next' and 1 or -1

  -- Walk to the commit's boundary in the direction of travel, then step past it.
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
-- mark starting past where the marked region began (`from_top_relative`, in
-- new-side line numbers). Strict comparison matters: a partially marked hunk
-- splits, and the remainder above the marked rows keeps the original start
-- line — skipping it lands on the remainder (or next hunk) below the marked
-- lines instead of pulling the cursor back up. Returns nil when nothing
-- starts past the marked region (review moves on to the next file).
function M.hunk_past_position(marks, from_top_relative)
  for i, mark in ipairs(marks) do
    if mark.top_relative > from_top_relative then return i end
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
        -- First match after current = next_file; we're done.
        next_file = to_ref(node)
        break
      elseif node.entry.status.filepath == current_filepath then
        found_current = true
      else
        -- Last non-current match before current becomes prev_file.
        prev_file = to_ref(node)
      end
    end
  end

  return next_file, prev_file, first_file
end

return M
