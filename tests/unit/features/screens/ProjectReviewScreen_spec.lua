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

  it('quits, saving, within one main-loop turn', function()
    H.open('file')
    local screen = H.screen()
    H.keys('S')
    screen:enqueue(function() screen:quit() end)
    eq({ false, true }, { screen._running, screen._destroyed })
    eq({}, H.errors)
  end)

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
    -- x.lua's last hunk, which lands on README; j, typed during that mark,
    -- still runs
    H.keys('sj')
    eq({ 'unseen src/b/y.lua', '1/1 inside' }, { H.entry(), H.hunk() })
    H.assert_consistent()
    eq({}, H.errors)
  end)

  it('drops mark keys a held key sent while a mark ran', function()
    H.open('file')
    H.keys('jjj')
    -- x.lua's last hunk only: the repeats came packed, before it was done
    H.keys(string.rep('s', 12))
    eq({ 'unseen docs/README.md', '1/1 inside' }, { H.entry(), H.hunk() })
    H.assert_consistent()
    eq({}, H.errors)
  end)

  it('runs taps typed while a slow mark ran, once it is done', function()
    H.open('file')
    local model = H.screen().model
    local mark_selections = model.mark_selections
    model.mark_selections = function(...)
      local start = vim.uv.hrtime()
      while vim.uv.hrtime() - start < 150e6 do
      end
      return mark_selections(...)
    end
    H.keys('jjj')
    -- x.lua's last hunk, then README
    H.keys('ss', 300)
    eq('unseen src/b/y.lua', H.entry())
    H.assert_consistent()
    eq({}, H.errors)
  end)

  it('judges a batch of mark keys by their spacing, and holds stay held', function()
    H.open('file')
    local screen = H.screen()
    local function settle(ms_ago, count)
      local batch = { started_at = vim.uv.hrtime() / 1e6 - ms_ago, count = count }
      screen:settle_batch(batch)
      return batch.taps
    end
    eq(true, settle(100, 1))
    eq(true, settle(300, 3))
    eq(false, settle(100, 3))
    -- The held key's last batch, with one repeat in a slow mark
    eq(false, settle(200, 1))
  end)

  it('runs mark keys pressed after a mark is done, and every one from a macro', function()
    H.open('file')
    H.keys('jjj')
    -- x.lua's last hunk, then README
    H.keys('s')
    H.keys('s')
    eq('unseen src/b/y.lua', H.entry())
    -- y.lua and z.lua whole
    vim.fn.setreg('q', 's')
    H.keys('2@q')
    eq('unseen gone.txt', H.entry())
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

describe('ProjectReviewScreen browse', function()
  H.use_repo()

  local function git(...)
    return H.run(vim.list_extend({ 'git', '-C', H.repo }, { ... }), H.repo)
  end

  -- The list's title, its section titles, and its files' entries in order
  local function listing()
    local screen = H.screen()
    local sections = vim.tbl_map(function(section) return section.title end, screen.model:get_entries())
    local entries = vim.tbl_map(function(node) return H.describe(screen.model:lookup(node.id)) end, screen.list_view:file_nodes())
    return { screen.list_view.state.title, sections, entries }
  end

  it('lists the commits of a range away from HEAD, in one section', function()
    git('checkout', '-q', 'main')
    H.open('commit', { browse = 'feature~3..feature~1' })
    eq({
      'feature~3..feature~1',
      { 'Changes' },
      { 'unseen gone.txt @feat: rename and delete', 'unseen new.txt @feat: rename and delete', 'unseen img.bin @feat: binary' },
    }, listing())
    eq({}, H.errors)
  end)

  it('lists the files of a range, which ends at HEAD unless it says', function()
    H.open('file', { browse = 'feature~1' })
    eq({ 'feature~1..HEAD', { 'Changes' }, { 'unseen a/x.lua', 'unseen docs/README.md', 'unseen src/b/y.lua' } }, listing())
    eq({}, H.errors)
  end)

  for _, kind in ipairs({ 'file', 'commit' }) do
    it('steps through its range as an unmarked review does (by ' .. kind .. ')', function()
      H.open(kind)
      local review = { listing()[3], H.walk('j', 8) }
      H.close()
      H.open(kind, { browse = 'main..feature' })
      eq(review, { listing()[3], H.walk('j', 8) })
      eq({}, H.errors)
    end)
  end

  it('maps no mark keys', function()
    local function mapped(mode)
      local keys = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, mode)) do
        if vim.tbl_contains({ 'j', 's', 'u', 'S', 'U', 'R' }, map.lhs) then keys[#keys + 1] = map.lhs end
      end
      table.sort(keys)
      return keys
    end

    H.open('commit')
    eq({ { 'R', 'S', 'U', 'j', 's', 'u' }, { 's', 'u' } }, { mapped('n'), mapped('x') })
    H.close()

    H.open('commit', { browse = 'main..feature' })
    eq({ { 'j' }, {} }, { mapped('n'), mapped('x') })
    H.focus('list')
    eq({ 'j' }, mapped('n'))
    eq({}, H.errors)
  end)

  it('stores nothing, and reopens on the entry it was closed on', function()
    H.open('commit', { browse = 'main..feature' })
    H.keys('jjj')
    local entry = H.entry()
    assert.are_not.same('unseen a/x.lua @feat: add core', entry)
    H.close()
    eq({ '', '' }, { vim.fn.glob(vim.env.XDG_STATE_HOME .. '/**'), vim.fn.glob(vim.env.XDG_DATA_HOME .. '/**') })

    H.open('commit', { browse = 'main..feature' })
    eq(entry, H.entry())
    eq({}, H.errors)
  end)

  it('refuses a range it cannot browse', function()
    local function refused(range)
      H.errors = {}
      eq(nil, H.open('commit', { browse = range }))
      return H.errors
    end
    eq({ { 'Specify a range to browse, e.g. main~5..main' } }, refused(''))
    eq({ { 'Not a commit: nope' } }, refused('main..nope'))
    eq({ { 'No changes in feature..feature' } }, refused('feature..feature'))
    eq(1, #refused('nope..feature'))
  end)
end)

describe('ProjectReviewScreen layout', function()
  H.use_repo()

  local columns, lines = vim.o.columns, vim.o.lines
  after_each(function()
    vim.o.columns, vim.o.lines = columns, lines
    require('vgit.settings.scene'):set('diff_wrap', false)
  end)

  -- Every window's { row, col, width, height } by component, or 'hidden'
  local function geometry()
    local rects = {}
    local function add(name, window)
      local config = vim.api.nvim_win_get_config(window.win_id)
      rects[name] = config.hide and 'hidden' or { config.row, config.col, config.width, config.height }
    end
    for name, component in pairs(H.screen().scene.components) do
      add(name, component.window)
      if component.elements.header then add(name .. ' header', component.elements.header.window) end
    end
    return rects
  end

  for _, kind in ipairs({ 'file', 'commit' }) do
    for _, layout in ipairs({ 'unified', 'split' }) do
      it(string.format('fits a resized editor as a fresh open would (by %s, %s)', kind, layout), function()
        vim.o.columns, vim.o.lines = 200, 50
        H.open(kind, { layout = layout })
        H.keys('j')
        local before, position = geometry(), { H.entry(), H.hunk() }

        vim.o.columns, vim.o.lines = 150, 40
        local resized = geometry()
        assert.are_not.same(before, resized)
        eq(position, { H.entry(), H.hunk() })

        H.close()
        H.open(kind, { layout = layout })
        eq(resized, geometry())
        eq({}, H.errors)
      end)
    end
  end

  it('toggles wrap from either pane, for screens opened later too', function()
    local function wraps()
      local scene = H.screen().scene
      return { vim.wo[scene:get('previous').window.win_id].wrap, vim.wo[scene:get('current').window.win_id].wrap }
    end

    H.open('commit', { layout = 'split' })
    H.focus('list')
    local position = { H.entry(), H.hunk() }
    eq({ false, false }, wraps())
    H.keys('gw')
    eq({ true, true }, wraps())
    eq(position, { H.entry(), H.hunk() })

    H.close()
    H.open('file', { layout = 'split' })
    eq({ true, true }, wraps())
    H.focus('diff')
    H.keys('gw')
    eq({ false, false }, wraps())
    eq({}, H.errors)
  end)

  it('moves the message box and diff with a dragged list boundary', function()
    vim.o.columns, vim.o.lines = 200, 50
    H.open('commit', { layout = 'split' })
    H.screen():apply_list_width(90)
    local rects = geometry()
    local message, previous, current = rects['commit_message header'], rects.previous, rects.current
    -- List and message box widths, where the diff starts, where it ends
    eq({ 90, 90, 90, 200 }, { rects.list[3], message[3], previous[2], current[2] + current[3] })
  end)

  it('survives an editor too small for its layout', function()
    H.open('commit', { layout = 'split' })
    vim.o.columns, vim.o.lines = 30, 8
    vim.o.columns, vim.o.lines = 120, 40
    H.keys('j')
    eq({}, H.errors)
  end)
end)
