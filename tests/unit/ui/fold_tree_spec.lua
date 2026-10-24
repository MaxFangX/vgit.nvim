local fold_tree = require('vgit.ui.fold_tree')

local eq = assert.are.same

local function file(id)
  return { id = id, value = id }
end

local function fold(value, items, open)
  return { value = value, items = items, open = open ~= false }
end

local function ids(nodes)
  return vim.tbl_map(function(node) return node.id end, nodes)
end

local function values(nodes)
  return vim.tbl_map(function(node) return node.value end, nodes)
end

describe('fold_tree:', function()
  -- Seen > a > a.lua; Unseen > (collapsed) commit > b > b.lua, c.lua
  local folds

  before_each(function()
    folds = {
      fold('Seen', { fold('a', { file('a.lua') }) }),
      fold('Unseen', {
        fold('commit', { fold('b', { file('b.lua') }), file('c.lua') }, false),
      }),
    }
  end)

  describe('file_nodes', function()
    it('lists file nodes in display order, collapsed folds included', function()
      eq({ 'a.lua', 'b.lua', 'c.lua' }, ids(fold_tree.file_nodes(folds)))
    end)

    it('is empty without folds', function()
      eq({}, fold_tree.file_nodes(nil))
    end)
  end)

  describe('first_file', function()
    it('is the node itself for a file', function()
      local node = folds[1].items[1].items[1]
      eq(node, fold_tree.first_file(node))
    end)

    it('is the first file under a fold, collapsed or not', function()
      eq('a.lua', fold_tree.first_file(folds[1]).id)
      eq('b.lua', fold_tree.first_file(folds[2]).id)
    end)

    it('is nil for a fold without files', function()
      eq(nil, fold_tree.first_file(fold('empty', {})))
    end)
  end)

  describe('path_to', function()
    it('returns the nodes from the root down to the file', function()
      eq({ 'Unseen', 'commit', 'b', 'b.lua' }, values(fold_tree.path_to(folds, 'b.lua')))
    end)

    it('matches file nodes only', function()
      -- A fold carrying the id must not end the path early
      local folder = fold('lua', { file('lua/x.lua') })
      folder.id = 'lua/x.lua'
      eq({ 'lua', 'lua/x.lua' }, values(fold_tree.path_to({ folder }, 'lua/x.lua')))
    end)

    it('is nil for an unknown id', function()
      eq(nil, fold_tree.path_to(folds, 'nope'))
    end)
  end)
end)
