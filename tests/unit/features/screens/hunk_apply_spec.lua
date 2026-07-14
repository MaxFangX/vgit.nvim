local git_hunks = require('vgit.git.git_hunks')
local hunk_apply = require('vgit.features.screens.hunk_apply')

local eq = assert.are.same

-- Diff two in-memory contents (reponame only matters for very large files)
local function live(a, b)
  return git_hunks.live('.', a, b)
end

-- Full-hunk selections for every hunk of a diff
local function all_hunks(hunks)
  local selections = {}
  for _, hunk in ipairs(hunks) do
    selections[#selections + 1] = { hunk = hunk, rows = nil }
  end
  return selections
end

describe('hunk_apply:', function()
  describe('lines_equal', function()
    it('compares line arrays', function()
      eq(hunk_apply.lines_equal({ 'a', 'b' }, { 'a', 'b' }), true)
      eq(hunk_apply.lines_equal({ 'a', 'b' }, { 'a' }), false)
      eq(hunk_apply.lines_equal({ 'a' }, { 'b' }), false)
      eq(hunk_apply.lines_equal({}, {}), true)
    end)
  end)

  describe('apply/reverse round trips', function()
    local cases = {
      { name = 'whole-file add', a = {}, b = { 'a', 'b', 'c' } },
      { name = 'whole-file delete', a = { 'a', 'b', 'c' }, b = {} },
      { name = 'change middle', a = { 'a', 'b', 'c' }, b = { 'a', 'B', 'c' } },
      { name = 'insert top', a = { 'a', 'b' }, b = { 'x', 'a', 'b' } },
      { name = 'insert bottom', a = { 'a', 'b' }, b = { 'a', 'b', 'x' } },
      { name = 'delete top', a = { 'a', 'b', 'c' }, b = { 'b', 'c' } },
      { name = 'uneven change', a = { 'a', 'b', 'c', 'd' }, b = { 'a', 'X', 'd' } },
      {
        name = 'mixed multi-hunk',
        a = { 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' },
        b = { 'a', 'B', 'c', 'd', 'x', 'e', 'f', 'h', 'z' },
      },
    }

    for _, case in ipairs(cases) do
      it('applies all hunks to reach the new content (' .. case.name .. ')', function()
        local selections = all_hunks(live(case.a, case.b))
        eq(hunk_apply.apply_selections(case.a, selections, 'apply'), case.b)
      end)

      it('reverses all hunks to reach the old content (' .. case.name .. ')', function()
        local selections = all_hunks(live(case.a, case.b))
        eq(hunk_apply.apply_selections(case.b, selections, 'reverse'), case.a)
      end)
    end

    it('round-trips randomized contents', function()
      -- Deterministic LCG so failures are reproducible
      local seed = 42
      local function rand(n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return (seed % n) + 1
      end

      for _ = 1, 100 do
        local a, b = {}, {}
        for _ = 1, rand(30) do a[#a + 1] = 'line' .. rand(10) end
        for _ = 1, rand(30) do b[#b + 1] = 'line' .. rand(10) end

        local selections = all_hunks(live(a, b))
        eq(hunk_apply.apply_selections(a, selections, 'apply'), b)
        eq(hunk_apply.apply_selections(b, selections, 'reverse'), a)
      end
    end)
  end)

  describe('partial row application', function()
    it('applies selected rows of an add hunk', function()
      local a = { 'ctx1', 'ctx2' }
      local b = { 'ctx1', 'n1', 'n2', 'n3', 'n4', 'ctx2' }
      local hunks = live(a, b)
      eq(#hunks, 1)

      local out = hunk_apply.apply(a, hunks[1], { [1] = true, [2] = true })
      eq(out, { 'ctx1', 'n1', 'n2', 'ctx2' })

      -- Marking the remainder converges to b
      local rest = live(out, b)
      eq(hunk_apply.apply(out, rest[1], nil), b)
    end)

    it('applies a selected row of a change hunk (pairs removed/added)', function()
      local a = { 'A', 'B', 'ctx' }
      local b = { 'A2', 'B2', 'ctx' }
      local hunks = live(a, b)

      local out = hunk_apply.apply(a, hunks[1], { [1] = true })
      eq(out, { 'A2', 'B', 'ctx' })
    end)

    it('reverses a selected row from the seen side', function()
      local a = { 'A', 'B', 'ctx' }
      local approved = { 'A2', 'B', 'ctx' }
      local seen_hunks = live(a, approved)

      eq(hunk_apply.reverse(approved, seen_hunks[1], { [1] = true }), a)
    end)

    it('applies a selected row of a delete hunk', function()
      local a = { 'ctx', 'd1', 'd2', 'd3' }
      local hunks = live(a, { 'ctx' })

      eq(hunk_apply.apply(a, hunks[1], { [2] = true }), { 'ctx', 'd1', 'd3' })
    end)

    it('handles uneven change hunks (added rows without removed pair)', function()
      local a = { 'r1', 'r2', 'ctx' }
      local b = { 'a1', 'a2', 'a3', 'ctx' }
      local hunks = live(a, b)

      eq(hunk_apply.apply(a, hunks[1], { [3] = true }), { 'r1', 'r2', 'a3', 'ctx' })
      eq(hunk_apply.apply(a, hunks[1], { [1] = true, [3] = true }), { 'a1', 'r2', 'a3', 'ctx' })
    end)
  end)

  describe('incremental marking', function()
    it('converges to current by marking one hunk at a time', function()
      local base = { 'a', 'b', 'c', 'd', 'e' }
      local current = { 'a', 'B', 'c', 'x', 'd', 'E' }
      local approved = base

      for _ = 1, 10 do
        local hunks = live(approved, current)
        if #hunks == 0 then break end
        approved = hunk_apply.apply(approved, hunks[1], nil)
      end

      eq(approved, current)
    end)
  end)
end)
