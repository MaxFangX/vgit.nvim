local git_hunks = require('vgit.git.git_hunks')

local eq = assert.are.same

local function numbered(n)
  local lines = {}
  for i = 1, n do
    lines[i] = 'line ' .. i
  end
  return lines
end

describe('git_hunks.live:', function()
  it('diffs files of thousands of lines, NULs included', function()
    local old = numbered(6000)
    local new = vim.list_slice(old)
    new[5500] = 'changed\0with a NUL'

    local hunks = git_hunks.live(old, new)
    eq(#hunks, 1)
    eq(hunks[1].diff, { '-line 5500', '+changed\0with a NUL' })
  end)

  it('diffs a large deletion from the old side', function()
    local hunks = git_hunks.live(numbered(20000), {})
    eq(#hunks, 1)
    eq(hunks[1].stat, { added = 0, removed = 20000 })
  end)

  it('returns no hunks for two empty sides', function()
    eq(git_hunks.live({}, {}), {})
  end)
end)
