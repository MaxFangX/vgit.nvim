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

  describe('rebase', function()
    -- Rebase diff(old_base -> approved) onto new_base
    local function rebase(old_base, approved, new_base)
      return hunk_apply.rebase(live(old_base, approved), old_base, new_base)
    end

    it('reproduces approved when the base is unchanged', function()
      local old_base = { 'a', 'b', 'c', 'd' }
      local approved = { 'a', 'B', 'c', 'd', 'x' }

      local out, dropped = rebase(old_base, approved, old_base)
      eq(out, approved)
      eq(dropped, 0)
    end)

    it('carries the approved delta across unrelated insertions above', function()
      local old_base = { 'fn one', 'fn two', 'fn three' }
      local approved = { 'fn one', 'fn TWO', 'fn three' }
      local new_base = { 'header', 'import', 'fn one', 'fn two', 'fn three' }

      local out, dropped = rebase(old_base, approved, new_base)
      eq(out, { 'header', 'import', 'fn one', 'fn TWO', 'fn three' })
      eq(dropped, 0)
    end)

    it('survives rename-style drift on unrelated lines', function()
      -- An ancestor commit renamed get_address; the approved delta elsewhere
      -- must survive without showing the rename as seen/unseen drift.
      local old_base = { 'fn get_address', 'call get_address', 'fn other', 'unrelated' }
      local approved = { 'fn get_address', 'call get_address', 'fn other_v2', 'unrelated' }
      local new_base = { 'fn get_next_unused_address', 'call get_next_unused_address', 'fn other', 'unrelated' }

      local out, dropped = rebase(old_base, approved, new_base)
      eq(out, { 'fn get_next_unused_address', 'call get_next_unused_address', 'fn other_v2', 'unrelated' })
      eq(dropped, 0)
    end)

    it('drops only the conflicted hunk, keeping the rest approved', function()
      local old_base = { 'top', 'x1', 'mid1', 'mid2', 'mid3', 'bottom', 'y1' }
      -- Two approved hunks: change x1 -> X1 and y1 -> Y1
      local approved = { 'top', 'X1', 'mid1', 'mid2', 'mid3', 'bottom', 'Y1' }
      -- New base rewrote y1's region; x1's region is intact
      local new_base = { 'top', 'x1', 'mid1', 'mid2', 'mid3', 'bottom', 'y1-rewritten' }

      local out, dropped = rebase(old_base, approved, new_base)
      eq(out, { 'top', 'X1', 'mid1', 'mid2', 'mid3', 'bottom', 'y1-rewritten' })
      eq(dropped, 1)
    end)

    it('relocates a pure insertion by its context', function()
      local old_base = { 'a', 'b', 'c' }
      local approved = { 'a', 'b', 'inserted', 'c' }
      local new_base = { 'pre1', 'pre2', 'a', 'b', 'c', 'post' }

      local out, dropped = rebase(old_base, approved, new_base)
      eq(out, { 'pre1', 'pre2', 'a', 'b', 'inserted', 'c', 'post' })
      eq(dropped, 0)
    end)

    it('drops a pure insertion whose context vanished', function()
      local old_base = { 'a', 'b', 'c' }
      local approved = { 'a', 'b', 'inserted', 'c' }
      local new_base = { 'x', 'y', 'z' }

      local out, dropped = rebase(old_base, approved, new_base)
      eq(out, new_base)
      eq(dropped, 1)
    end)

    it('disambiguates repeated content by context', function()
      local old_base = { 'ctxA', 'dup', 'ctxB', 'dup', 'ctxC' }
      -- Approve a change to the second dup (between ctxB and ctxC)
      local approved = { 'ctxA', 'dup', 'ctxB', 'DUP', 'ctxC' }
      local new_base = { 'new-top', 'ctxA', 'dup', 'ctxB', 'dup', 'ctxC' }

      local out, dropped = rebase(old_base, approved, new_base)
      eq(out, { 'new-top', 'ctxA', 'dup', 'ctxB', 'DUP', 'ctxC' })
      eq(dropped, 0)
    end)

    it('keeps an approved deletion whose region is intact in the new base', function()
      local old_base = { 'a', 'b' }
      local approved = {}
      local new_base = { 'a', 'b', 'c' }

      -- a,b stay deleted (approved); the appended c reverts to unseen
      local out, dropped = rebase(old_base, approved, new_base)
      eq(out, { 'c' })
      eq(dropped, 0)
    end)

    it('drops an approved deletion whose region changed', function()
      local old_base = { 'a', 'b' }
      local approved = {}
      local new_base = { 'a', 'B-changed', 'c' }

      local out, dropped = rebase(old_base, approved, new_base)
      eq(out, new_base)
      eq(dropped, 1)
    end)

    it('drops an approved whole-file addition onto a diverged base', function()
      local old_base = {}
      local approved = { 'mine1', 'mine2' }
      local new_base = { 'theirs' }

      local out, dropped = rebase(old_base, approved, new_base)
      eq(out, new_base)
      eq(dropped, 1)
    end)

    it('keeps an approved whole-file addition on a still-empty base', function()
      local old_base = {}
      local approved = { 'mine1', 'mine2' }

      local out, dropped = rebase(old_base, approved, {})
      eq(out, approved)
      eq(dropped, 0)
    end)

    it('reproduces approved for randomized diffs on an unchanged base', function()
      local seed = 1337
      local function rand(n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return (seed % n) + 1
      end

      for _ = 1, 100 do
        local a, b = {}, {}
        for _ = 1, rand(30) do a[#a + 1] = 'line' .. rand(10) end
        for _ = 1, rand(30) do b[#b + 1] = 'line' .. rand(10) end

        local out, dropped = rebase(a, b, a)
        eq(out, b)
        eq(dropped, 0)
      end
    end)
  end)
end)
