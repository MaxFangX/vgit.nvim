local Object = require('vgit.core.Object')

local GitHunk = Object:extend()

function GitHunk:constructor(header)
  local hunk = {
    header = nil,
    top = nil,
    bot = nil,
    type = nil,
    diff = {},
    stat = {
      added = 0,
      removed = 0,
    },
  }

  if not header then return hunk end

  local previous, current

  if type(header) == 'string' then
    previous, current = self:parse_header(header)
  else
    previous, current = unpack(header)
    header = self:generate_header(previous, current)
  end

  hunk.header = header
  hunk.top = current[1]
  hunk.bot = current[1] + current[2] - 1

  if current[2] == 0 then
    hunk.bot = hunk.top
    hunk.type = 'remove'
  elseif previous[2] == 0 then
    hunk.type = 'add'
  else
    hunk.type = 'change'
  end

  return hunk
end

function GitHunk:generate_header(previous, current)
  return string.format('@@ -%s,%s +%s,%s @@', previous[1], previous[2], current[1], current[2])
end

function GitHunk:parse_header(header)
  header = header or self.header
  local diffkey = vim.trim(vim.split(header, '@@', true)[2])
  local parsed_diffkey = vim.split(diffkey, ' ')
  local parsed_header = {}

  for i = 1, #parsed_diffkey do
    parsed_header[#parsed_header + 1] = vim.split(string.sub(parsed_diffkey[i], 2), ',')
  end

  local previous, current = parsed_header[1], parsed_header[2]

  previous[1] = tonumber(previous[1])
  previous[2] = tonumber(previous[2]) or 1
  current[1] = tonumber(current[1])
  current[2] = tonumber(current[2]) or 1

  return previous, current
end

function GitHunk:parse_diff(diff)
  diff = diff or self.diff
  local removed_lines = {}
  local added_lines = {}

  for i = 1, #diff do
    local line = diff[i]
    local type = line:sub(1, 1)
    local cleaned_diff_line = line:sub(2, #line)

    if type == '+' then
      added_lines[#added_lines + 1] = cleaned_diff_line
    elseif type == '-' then
      removed_lines[#removed_lines + 1] = cleaned_diff_line
    end
  end

  return removed_lines, added_lines
end

function GitHunk:push(line)
  local stat = self.stat
  local type = line:sub(1, 1)

  if type == '+' then
    stat.added = stat.added + 1
  elseif type == '-' then
    stat.removed = stat.removed + 1
  end

  local diff = self.diff

  diff[#diff + 1] = line

  return self
end

local fnv1a = require('vgit.core.utils').str.fnv1a

-- Compute content-based identifier for this hunk.
-- Hashes diff + 5 lines of surrounding context to disambiguate identical hunks
-- within the same file (mark keys already distinguish different files).
function GitHunk:get_content_id(file_lines, context_size)
  if #self.diff == 0 then return 'empty' end

  if file_lines and context_size and context_size > 0 then
    local context = {}

    for i = math.max(1, self.top - context_size), self.top - 1 do
      context[#context + 1] = file_lines[i] or ''
    end

    for _, line in ipairs(self.diff) do
      context[#context + 1] = line
    end

    for i = self.bot + 1, math.min(#file_lines, self.bot + context_size) do
      context[#context + 1] = file_lines[i] or ''
    end

    return fnv1a(table.concat(context, '\n'))
  end

  return fnv1a(table.concat(self.diff, '\n'))
end

-- Return the inverse hunk: sides swapped, removed and added lines flipped.
-- Forward-applying the inverse undoes the hunk. This positions better than
-- `git apply --reverse`: git locates a patch by its old-side line numbers
-- even when reversing, and only the inverse hunk is numbered by the side
-- the undo actually targets (e.g. the index, for a HEAD->index hunk).
function GitHunk:invert()
  local previous, current = self:parse_header()
  local removed, added = self:parse_diff()

  local inverted = GitHunk({ current, previous })
  for _, line in ipairs(added) do
    inverted:push('-' .. line)
  end
  for _, line in ipairs(removed) do
    inverted:push('+' .. line)
  end

  return inverted
end

-- Build a sub-hunk containing only the selected pair rows (row r pairs
-- removed[r]/added[r], the pairing the diff layouts render). The selection
-- must be contiguous (it comes from a visual range); the sub-hunk gets a
-- renumbered header so it can be applied on its own. Returns self when the
-- selection covers the whole hunk, nil when it selects nothing.
function GitHunk:select_rows(rows)
  local lo, hi
  for r in pairs(rows) do
    if not lo or r < lo then lo = r end
    if not hi or r > hi then hi = r end
  end
  if not lo then return nil end

  local removed, added = self:parse_diff()
  if lo <= 1 and hi >= math.max(#removed, #added) then return self end

  local diff = {}
  local removed_count, added_count = 0, 0
  for r = lo, math.min(hi, #removed) do
    diff[#diff + 1] = '-' .. removed[r]
    removed_count = removed_count + 1
  end
  for r = lo, math.min(hi, #added) do
    diff[#diff + 1] = '+' .. added[r]
    added_count = added_count + 1
  end
  if #diff == 0 then return nil end

  local previous, current = self:parse_header()

  -- A selected span starts at its row offset into the hunk's span. When the
  -- selection leaves a side empty, git numbers that zero-count side by the
  -- line BEFORE the change: the last unselected line of the hunk preceding
  -- the selection (or the original anchor if that side was already empty).
  local old_start
  if removed_count > 0 then
    old_start = previous[1] + lo - 1
  else
    old_start = previous[2] == 0 and previous[1] or previous[1] + math.min(lo - 1, #removed) - 1
  end

  local new_start
  if added_count > 0 then
    new_start = current[1] + lo - 1
  else
    new_start = current[2] == 0 and current[1] or current[1] + math.min(lo - 1, #added) - 1
  end

  local sub = GitHunk({ { old_start, removed_count }, { new_start, added_count } })
  for _, line in ipairs(diff) do
    sub:push(line)
  end

  return sub
end

return GitHunk
