-- Not a module path: plenary runs specs without the repo root on package.path
local H = dofile('tests/helpers/review_screen.lua')

local eq = assert.are.same

describe('ProjectReviewByCommitScreen', function()
  H.use_repo()

  local ORDER = {
    'unseen a/x.lua @feat: add core',
    'unseen src/b/y.lua @feat: add core',
    'unseen src/c/z.lua @feat: add core',
    'unseen gone.txt @feat: rename and delete',
    'unseen new.txt @feat: rename and delete',
    'unseen img.bin @feat: binary',
    'unseen a/x.lua @fix: more core',
    'unseen docs/README.md @fix: more core',
    'unseen src/b/y.lua @fix: more core',
  }

  it('walks every commit\'s files in display order with j, wrapping', function()
    H.open('commit')
    H.focus('list')
    eq(vim.list_extend(vim.deepcopy(ORDER), { ORDER[1] }), H.walk('j', 9))
    eq({ ORDER[1], ORDER[9] }, H.walk('k', 1))
  end)

  it('J/K in the list jump between commits', function()
    H.open('commit')
    H.focus('list')
    eq({ ORDER[1], ORDER[4], ORDER[6], ORDER[7], ORDER[1] }, H.walk('J', 4))
    eq({ ORDER[1], ORDER[9], ORDER[6] }, H.walk('K', 2))
  end)

  it('J/K from a section header land on its first commit and the one before', function()
    H.open('commit')
    H.focus('list')
    H.keys('gg')
    eq('Unseen', H.row())
    H.keys('J')
    eq(ORDER[1], H.entry())
    H.keys('gg')
    H.keys('K')
    eq(ORDER[9], H.entry())
    H.assert_consistent()
  end)

  it('steps hunks across commits from the diff', function()
    H.open('commit')
    eq({ ORDER[1], '1/2 inside' }, { H.entry(), H.hunk() })
    H.keys('j')
    H.keys('j')
    eq({ ORDER[2], '1/1 inside' }, { H.entry(), H.hunk() })
    H.keys('k')
    eq({ ORDER[1], '2/2 inside' }, { H.entry(), H.hunk() })
    H.assert_consistent()
  end)

  for _, layout in ipairs({ 'unified', 'split' }) do
    it('quits from a change onto the line that replaced it (' .. layout .. ')', function()
      H.open('commit', { layout = layout })
      H.focus('list')
      H.keys('k')
      H.focus('diff')
      eq({ ORDER[9], '1/1 inside' }, { H.entry(), H.hunk() })
      H.keys('<esc>')
      eq(nil, H.screen())
      eq({ H.repo .. '/src/b/y.lua', 3 }, { vim.api.nvim_buf_get_name(0), vim.fn.line('.') })
    end)
  end

  it('steps from a section header into its section', function()
    H.open('commit')
    H.keys('S')
    H.focus('list')
    H.keys('gg')
    eq('Seen', H.row())
    H.keys('j')
    eq('seen a/x.lua @feat: add core', H.entry())
    H.assert_consistent()
  end)

  it('U on the unseen half of a partly seen file stays on it', function()
    H.open('commit')
    H.keys('s')
    eq({ ORDER[1], '1/1 inside' }, { H.entry(), H.hunk() })
    H.keys('U')
    eq({ ORDER[1], '1/2 inside' }, { H.entry(), H.hunk() })
    H.assert_consistent()
    H.keys('j')
    H.keys('j')
    eq(ORDER[2], H.entry())
  end)

  it('R re-anchors on the current file, now unseen', function()
    H.open('commit')
    H.keys('S')
    H.keys('k')
    eq('seen a/x.lua @feat: add core', H.entry())
    H.keys('R')
    eq({ ORDER[1], '1/2 inside' }, { H.entry(), H.hunk() })
    H.assert_consistent()
  end)

  it('opens on the commit whose hunk holds the source line', function()
    vim.cmd.edit('a/x.lua')
    vim.cmd('55')
    H.open('commit')
    eq({ 'unseen a/x.lua @fix: more core', '2/2 inside' }, { H.entry(), H.hunk() })
    H.close()

    vim.cmd('5')
    H.open('commit')
    eq({ 'unseen a/x.lua @feat: add core', '1/2 inside' }, { H.entry(), H.hunk() })
    H.assert_consistent()
  end)

  it('resumes an unseen entry of the source file from a line no hunk holds', function()
    vim.cmd.edit('a/x.lua')
    vim.cmd('5')
    H.open('commit')
    eq(ORDER[1], H.entry())
    H.close()

    vim.cmd('30')
    H.open('commit')
    eq(ORDER[1], H.entry())
    H.assert_consistent()
  end)

  it('opens on the source file\'s latest unseen commit otherwise', function()
    vim.cmd.edit('a/x.lua')
    vim.cmd('5')
    H.open('commit')
    eq(ORDER[1], H.entry())
    -- Leave the review on the file's Seen entry
    H.keys('S')
    H.keys('k')
    eq('seen a/x.lua @feat: add core', H.entry())
    H.close()

    vim.cmd.edit('a/x.lua')
    vim.cmd('5')
    H.open('commit')
    eq('unseen a/x.lua @fix: more core', H.entry())
    H.assert_consistent()
  end)

  it('reuses each commit\'s file tree until its files change', function()
    H.open('commit')
    local list_view = H.screen().list_view
    local function trees()
      local result = {}
      for _, section in ipairs(list_view.state.folds) do
        for _, commit in ipairs(section.items) do
          result[section.section_type .. ' ' .. commit.value] = commit.items
        end
      end
      return result
    end

    local before = trees()
    H.async(function() list_view:render() end)
    for key, tree in pairs(trees()) do
      assert(before[key] == tree, key)
    end

    -- S on a/x.lua changes commit 01's Unseen files only
    H.keys('S')
    for key, tree in pairs(trees()) do
      if key:match('^unseen 01') then
        assert(before[key] ~= tree, key)
      elseif before[key] then
        assert(before[key] == tree, key)
      end
    end
  end)

  it('S marks the file and moves on; the commit shows up under Seen', function()
    H.open('commit')
    H.keys('S')
    eq(ORDER[2], H.entry())
    H.assert_consistent()
    H.keys('k')
    eq('seen a/x.lua @feat: add core', H.entry())
    H.assert_consistent()
  end)
end)
