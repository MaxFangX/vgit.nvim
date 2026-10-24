local Diff = require('vgit.core.Diff')
local git_hunks = require('vgit.git.git_hunks')
local visual_selection = require('vgit.features.screens.visual_selection')

local eq = assert.are.same

-- One change hunk, b c d -> X Y, then a pure addition after f:
--   unified rows: 1 a, 2 -b, 3 -c, 4 -d, 5 +X, 6 +Y, 7 e, 8 f, 9 +Z
--   split rows:   1 a, 2 b|X, 3 c|Y, 4 d|_, 5 e, 6 f, 7 _|Z
local OLD = { 'a', 'b', 'c', 'd', 'e', 'f' }
local NEW = { 'a', 'X', 'Y', 'e', 'f', 'Z' }

local function diff(layout_type)
  return Diff():generate(git_hunks.live(OLD, NEW), NEW, layout_type)
end

local function set(...)
  local result = {}
  for _, i in ipairs({ ... }) do
    result[i] = true
  end
  return result
end

-- A partial line selection of hunk `index`
local function partial(index, removed, added)
  return { index = index, lines = { removed = removed, added = added } }
end

describe('visual_selection:', function()
  describe('lines_for_range', function()
    local unified = diff('unified')
    local function select(top, bot)
      return visual_selection.lines_for_range(unified, top, bot)
    end

    it('selects removed and added lines separately', function()
      eq({ partial(1, set(2), {}) }, select(3, 3))
      eq({ partial(1, set(3), set(1)) }, select(4, 5))
      eq({ partial(1, {}, set(2)) }, select(6, 7))
    end)

    it('selects a fully covered hunk whole', function()
      eq({ { index = 1 } }, select(1, 6))
    end)

    it('spans hunks', function()
      eq({ partial(1, {}, set(2)), { index = 2 } }, select(6, 9))
    end)

    it('is nil outside every hunk', function()
      eq(nil, select(7, 8))
    end)
  end)

  describe('for_range', function()
    it('selects pair rows in split', function()
      eq({ { index = 1, rows = set(2, 3) } }, visual_selection.for_range(diff('split'), 'split', 3, 4))
    end)

    it('folds unified rows onto their pair rows', function()
      -- c and d are removed lines 2 and 3, X is added line 1
      eq({ { index = 1, rows = set(1, 2, 3) } }, visual_selection.for_range(diff('unified'), 'unified', 3, 5))
    end)

    it('selects a fully covered hunk whole', function()
      eq({ { index = 1 }, { index = 2 } }, visual_selection.for_range(diff('split'), 'split', 1, 7))
    end)
  end)
end)
