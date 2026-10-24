-- Not a module path: plenary runs specs without the repo root on package.path
local H = dofile('tests/helpers/review_screen.lua')

local eq = assert.are.same

describe('ProjectReviewScreen keypress queue', function()
  H.use_repo()

  for _, kind in ipairs({ 'file', 'commit' }) do
    it('runs each job within one main-loop turn (by ' .. kind .. ')', function()
      H.open(kind)
      local screen = H.screen()
      -- A job that yielded would leave the runner suspended
      local function still_running(fn)
        screen:enqueue(fn)
        return screen._running
      end

      eq(false, still_running(function() screen:step_hunk('next') end))
      eq(false, still_running(function() screen:mark_hunk(true) end))
      eq(false, still_running(function() screen:mark_range(true, 1, 60) end))
      eq(false, still_running(function() screen:mark(true) end))
      eq(false, still_running(function() screen:step_file('next', true) end))
      eq(false, still_running(function() screen:jump_section('next') end))
      eq(false, still_running(function() screen:reset_marks() end))
      eq(false, still_running(function() screen:mark(false) end))
      H.assert_consistent()
      eq({}, H.errors)
    end)
  end

  it('shows a list row the cursor reached while a job ran', function()
    H.open('file')
    H.focus('list')
    local screen = H.screen()
    local _, lnum = screen.list_view:find_list_item(function(item)
      return item.id and H.describe(screen.model:lookup(item.id)) == 'unseen src/b/y.lua'
    end)
    -- A plain motion (arrow, click) handled in the middle of a job
    screen:enqueue(function()
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = 0 })
    end)
    H.settle()
    eq('unseen src/b/y.lua', H.entry())
    H.assert_consistent()
  end)

  it('marks what s and a visual range typed after it pointed at', function()
    H.open('file')
    -- s on hunk 1 is done before the next key reads the cursor, which is
    -- already on the next hunk's removed row; V then selects it alone
    vim.api.nvim_feedkeys('s', 'x', false)
    eq('x line 20', vim.api.nvim_get_current_line())
    vim.api.nvim_feedkeys('Vs', 'x', false)
    H.settle()
    eq({ { { 'x line 5' }, { 'x line 5 CHANGED' } }, { { 'x line 20' }, {} } }, H.hunks('seen a/x.lua'))
    eq({}, H.errors)
  end)

  it('runs every key of a burst, in order', function()
    H.open('file')
    H.keys('jjj')
    eq({ 'unseen a/x.lua', '4/4 inside' }, { H.entry(), H.hunk() })
    -- x.lua's last hunk, then README and y.lua whole
    H.keys('sss')
    eq({ 'unseen src/c/z.lua', '1/1 inside' }, { H.entry(), H.hunk() })
    H.assert_consistent()
    eq({}, H.errors)
  end)

  it('marks the hunk the previous key landed on', function()
    H.open('file')
    H.keys('j')
    H.keys('j')
    H.keys('j')
    H.keys('j')
    eq('unseen docs/README.md', H.entry())
    -- k leaves README for x.lua's last hunk; s marks that hunk and moves
    -- on to the next unseen file, README
    H.keys('ks')
    eq({ 'unseen docs/README.md', '1/1 inside' }, { H.entry(), H.hunk() })
    H.focus('list')
    H.keys('gg')
    H.keys('j')
    eq({ 'seen a/x.lua', '1/1 inside' }, { H.entry(), H.hunk() })
    H.keys('j')
    eq('unseen a/x.lua', H.entry())
    H.keys('j')
    eq('unseen docs/README.md', H.entry())
    eq({}, H.errors)
  end)

  it('runs keys pressed just before quit, then quits', function()
    H.open('file')
    H.focus('list')
    H.keys('S<esc>')
    eq(nil, H.screen())
    -- S moved on to README before the quit
    eq(H.repo .. '/docs/README.md', vim.api.nvim_buf_get_name(0))
    eq({}, H.errors)

    H.open('file')
    H.focus('list')
    H.keys('gg')
    H.keys('j')
    eq('seen a/x.lua', H.entry())
    eq({}, H.errors)
  end)

  it('drops the queue when the screen goes away', function()
    H.open('file')
    local screen = H.screen()
    H.keys('jjj', 0)
    H.close()
    eq({}, screen._jobs)
    eq({}, H.errors)
  end)
end)
