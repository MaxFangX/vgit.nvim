-- Shared helpers for navigating between files in screen entries.
-- Used by both ProjectDiffScreen and ProjectReviewScreen so they share a
-- single notion of "next file in section, with wrap-around" — independent
-- of which folders/commits are currently expanded in the list view.

local M = {}

-- Compare paths in path order: folders before files at each level, then alphabetically.
local function compare_paths(path_a, path_b)
  local parts_a = vim.split(path_a, '/')
  local parts_b = vim.split(path_b, '/')

  for i = 1, math.max(#parts_a, #parts_b) do
    local a, b = parts_a[i], parts_b[i]

    -- One path ended: the longer one is inside a folder, so it comes first.
    if not a then return false end
    if not b then return true end

    -- At this level, folder (has more parts after) comes before file (last part).
    local a_is_last = (i == #parts_a)
    local b_is_last = (i == #parts_b)
    if a_is_last ~= b_is_last then return not a_is_last end

    if a ~= b then return a < b end
  end

  return false
end

local function by_filepath(a, b)
  return compare_paths(a.status.filepath, b.status.filepath)
end

-- Append `files` to `out` in path-sorted order, tagging each with section/commit_hash.
local function append_sorted(out, files, section, commit_hash)
  local sorted = vim.list_extend({}, files)
  table.sort(sorted, by_filepath)
  for _, file in ipairs(sorted) do
    out[#out + 1] = { section = section, commit_hash = commit_hash, file = file }
  end
end

-- Build a flat list of all files in path order.
-- Handles two entry shapes:
--   - by-commit: section.commits[].files
--   - by-file:   section.entries
-- Each output info is { section = title, commit_hash = hash|nil, file = entry }.
function M.build_logical_file_list(entries)
  local files = {}
  for _, section in ipairs(entries or {}) do
    if section.commits then
      for _, commit_data in ipairs(section.commits) do
        append_sorted(files, commit_data.files or {}, section.title, commit_data.commit.hash)
      end
    elseif section.entries then
      append_sorted(files, section.entries, section.title, nil)
    end
  end
  return files
end

local function to_ref(info)
  return { filepath = info.file.status.filepath, commit_hash = info.commit_hash }
end

-- Find next/prev/first files among `all_files` matching `predicate`,
-- relative to (current_filepath, current_commit).
-- Each return value is { filepath, commit_hash } or nil.
--   first_file: first match in the filtered list (used for wrap-around).
function M.find_adjacent_files(all_files, current_filepath, current_commit, predicate)
  local next_file, prev_file, first_file = nil, nil, nil
  local found_current = false

  for _, info in ipairs(all_files) do
    if predicate(info) then
      first_file = first_file or to_ref(info)

      local is_current = info.file.status.filepath == current_filepath
        and (not current_commit or info.commit_hash == current_commit)

      if found_current then
        -- First match after current = next_file; we're done.
        next_file = to_ref(info)
        break
      elseif is_current then
        found_current = true
      else
        -- Last non-current match before current becomes prev_file.
        prev_file = to_ref(info)
      end
    end
  end

  return next_file, prev_file, first_file
end

return M
