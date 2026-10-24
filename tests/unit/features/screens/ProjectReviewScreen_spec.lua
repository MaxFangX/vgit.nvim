-- Not a module path: plenary runs specs without the repo root on package.path
local review = dofile('tests/helpers/review.lua')
local loop = require('vgit.core.loop')
local console = require('vgit.core.console')
local screen_manager = require('vgit.ui.screen_manager')
local scene_setting = require('vgit.settings.scene')

local eq = assert.are.same

-- End-to-end specs for the review screens: a throwaway repo, the real
-- screens, keys fed through their mappings.

local function run(cmd, cwd)
  local out = vim.fn.system(cmd)
  assert(vim.v.shell_error == 0, string.format('%s failed in %s: %s', vim.inspect(cmd), cwd, out))
  return out
end

local function numbered(prefix, n)
  local lines = {}
  for i = 1, n do
    lines[i] = prefix .. i
  end
  return lines
end

local function replace(lines, edits)
  local result = vim.deepcopy(lines)
  for i, line in pairs(edits) do
    result[i] = line
  end
  return result
end

-- A `main` + `feature` repo with four feature commits:
--   01 feat: add core        a/x.lua (2 hunks), new src/b/y.lua, src/c/z.lua
--   02 feat: rename and delete  old.txt -> new.txt (edited), gone.txt deleted
--   03 feat: binary          img.bin
--   04 fix: more core        a/x.lua (2 hunks), src/b/y.lua, docs/README.md
local function make_repo()
  local dir = vim.loop.fs_realpath(vim.fn.fnamemodify(vim.fn.tempname(), ':h')) .. '/vgit-review-' .. vim.loop.hrtime()
  vim.fn.mkdir(dir, 'p')

  local function git(...)
    return run(vim.list_extend({ 'git', '-C', dir }, { ... }), dir)
  end
  local function write(path, lines)
    vim.fn.mkdir(vim.fn.fnamemodify(dir .. '/' .. path, ':h'), 'p')
    vim.fn.writefile(lines, dir .. '/' .. path)
  end
  local function commit(message, body)
    git('add', '-A')
    if body then
      git('commit', '-qm', message, '-m', body)
    else
      git('commit', '-qm', message)
    end
  end

  git('init', '-q', '-b', 'main')
  git('config', 'user.email', 't@t')
  git('config', 'user.name', 't')

  local x = numbered('x line ', 60)
  write('a/x.lua', x)
  write('old.txt', numbered('old ', 30))
  write('gone.txt', numbered('gone ', 10))
  write('docs/README.md', { 'readme' })
  commit('base')
  git('checkout', '-qb', 'feature')

  x = replace(x, { [5] = 'x line 5 CHANGED', [40] = 'x line 40 CHANGED' })
  write('a/x.lua', x)
  write('src/b/y.lua', numbered('y ', 5))
  write('src/c/z.lua', numbered('z ', 5))
  commit('feat: add core')

  git('mv', 'old.txt', 'new.txt')
  write('new.txt', replace(numbered('old ', 30), { [15] = 'old 15 EDIT' }))
  git('rm', '-q', 'gone.txt')
  commit('feat: rename and delete', 'Body line one.')

  local fd = assert(io.open(dir .. '/img.bin', 'wb'))
  fd:write('\0\1\2binary\0')
  fd:close()
  commit('feat: binary')

  write('a/x.lua', replace(x, { [20] = 'x line 20 C4', [55] = 'x line 55 C4' }))
  write('src/b/y.lua', replace(numbered('y ', 5), { [3] = 'y 3 C4' }))
  write('docs/README.md', { 'readme', 'more' })
  commit('fix: more core')

  return dir
end

local H = {}

function H.screen()
  return screen_manager.active_screen
end

-- Let handlers (debounced or queued) and their renders finish
function H.settle(ms)
  vim.wait(ms or 120)
end

-- Run fn in a coroutine, as keymap and autocmd handlers do, and wait for it
function H.async(fn)
  local done = false
  loop.coroutine(function()
    fn()
    done = true
  end)()
  assert(vim.wait(10000, function() return done end), 'coroutine did not finish')
end

function H.open(kind, opts)
  opts = opts or {}
  scene_setting:set('diff_preference', opts.layout or 'unified')
  local name = kind == 'file' and 'project_review_by_file_screen' or 'project_review_by_commit_screen'
  H.async(function()
    screen_manager.create(name, 'main')
  end)
  H.settle()
  return H.screen()
end

function H.close()
  if H.screen() then H.async(screen_manager.destroy_active_screen) end
end

-- Feed keys through the mappings. CursorMoved fires from the main loop,
-- which vim.wait never reaches, so fire it as the main loop would.
function H.keys(keys, ms)
  local win, cursor = vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
  if win == vim.api.nvim_get_current_win() and not vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(0)) then
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = 0 })
  end
  H.settle(ms)
end

function H.focus(pane)
  H.screen().scene:get(pane == 'list' and 'list' or 'current'):focus()
  H.settle(20)
end

-- 'unseen a/x.lua' (by-file) or 'unseen a/x.lua @feat: add core' (by-commit)
function H.describe(entry)
  if not entry then return nil end
  local label = entry.type .. ' ' .. entry.filepath
  if entry.commit then label = label .. ' @' .. entry.commit.message end
  return label
end

function H.entry()
  return H.describe(H.screen().model:get_entry())
end

-- The list row under the cursor: its file entry's label, or its title
function H.row()
  local item = H.screen().list_view:get_current_list_item()
  if item and item.id then return H.describe(H.screen().model:lookup(item.id)) end
  return item and item.value
end

-- 'i/n position' for the diff cursor
function H.hunk()
  local index, total, position
  H.async(function()
    index, total, position = H.screen().diff_view:get_cursor_mark_position()
  end)
  if not index then return 'none' end
  return string.format('%d/%d %s', index, total, position)
end

-- The entry labelled `label` (see H.describe), or nil
function H.find(label)
  local screen = H.screen()
  for _, node in ipairs(screen.list_view:file_nodes()) do
    local entry = screen.model:lookup(node.id)
    if H.describe(entry) == label then return entry end
  end
end

-- The hunks of entry `label` as { removed lines, added lines } pairs
function H.hunks(label)
  local entry = H.find(label)
  if not entry then return nil end
  return vim.tbl_map(function(hunk)
    return { hunk:parse_diff() }
  end, H.screen().model:get_diff_for(entry).hunks)
end

-- Show entry `label` at hunk `hunk`
function H.select(label, hunk)
  local entry = assert(H.find(label), label)
  H.async(function() H.screen():select(entry.id, hunk) end)
end

-- Collect the diff pane's notifications from now on
function H.notifications()
  local notes = {}
  local diff_view = H.screen().diff_view
  diff_view.notify = function(view, msg)
    notes[#notes + 1] = vim.trim(msg)
    return getmetatable(view).notify(view, msg)
  end
  return notes
end

-- The list cursor and the diff pane agree on one entry
function H.assert_consistent()
  eq(H.entry(), H.row())
end

describe('ProjectReviewScreen', function()
  local repo, cwd

  local input, error = console.input, console.error
  local errors

  before_each(function()
    console.input = function() return 'y' end
    errors = {}
    console.error = function(msg)
      errors[#errors + 1] = msg
    end
    cwd = vim.loop.cwd()
    repo = make_repo()
    vim.cmd.cd(repo)
  end)

  after_each(function()
    H.close()
    vim.cmd('silent! %bwipeout!')
    vim.cmd.cd(cwd)
    vim.fn.delete(repo, 'rf')
    console.input, console.error = input, error
  end)

  -- After the hooks above, so the screen saves into the temp dir before it goes
  review.use_temp_homes()

  -- Walk `n` presses of `keys`, collecting the entry after each
  local function walk(keys, n)
    local seen = { H.entry() }
    for _ = 1, n do
      H.keys(keys)
      H.assert_consistent()
      seen[#seen + 1] = H.entry()
    end
    return seen
  end

  describe('by file', function()
    local ORDER = {
      'unseen a/x.lua',
      'unseen docs/README.md',
      'unseen src/b/y.lua',
      'unseen src/c/z.lua',
      'unseen gone.txt',
      'unseen img.bin',
      'unseen new.txt',
    }

    it('walks the list in display order with j and k, wrapping', function()
      H.open('file')
      H.focus('list')
      eq(vim.list_extend(vim.deepcopy(ORDER), { ORDER[1] }), walk('j', 7))
      eq({ ORDER[1], ORDER[7], ORDER[6] }, walk('k', 2))
    end)

    it('J/K in the list jump between folder headings', function()
      H.open('file')
      H.focus('list')
      H.keys('J')
      eq('docs', H.row())
      H.keys('J')
      eq('b', H.row())
      H.keys('K')
      eq('docs', H.row())
      -- Headings leave the diff alone
      eq('unseen a/x.lua', H.entry())
    end)

    it('steps hunks with j/k in the diff and crosses files at the edges', function()
      H.open('file')
      eq('1/4 inside', H.hunk())
      H.keys('j')
      H.keys('j')
      H.keys('j')
      eq({ 'unseen a/x.lua', '4/4 inside' }, { H.entry(), H.hunk() })
      H.keys('j')
      eq({ 'unseen docs/README.md', '1/1 inside' }, { H.entry(), H.hunk() })
      H.keys('k')
      eq({ 'unseen a/x.lua', '4/4 inside' }, { H.entry(), H.hunk() })
      H.assert_consistent()
    end)

    it('doesn\'t reload syntax to step hunks within a file', function()
      H.open('file')
      local loads = 0
      local autocmd = vim.api.nvim_create_autocmd('Syntax', { callback = function() loads = loads + 1 end })
      H.keys('j')
      H.keys('k')
      vim.api.nvim_del_autocmd(autocmd)
      eq({ 'unseen a/x.lua', 0 }, { H.entry(), loads })
    end)

    it('jumps to the file edge with J/K, then crosses', function()
      H.open('file')
      H.keys('J')
      eq({ 'unseen a/x.lua', '4/4 inside' }, { H.entry(), H.hunk() })
      H.keys('J')
      eq({ 'unseen docs/README.md', '1/1 inside' }, { H.entry(), H.hunk() })
      H.keys('K')
      eq({ 'unseen a/x.lua', '4/4 inside' }, { H.entry(), H.hunk() })
      H.keys('K')
      eq({ 'unseen a/x.lua', '1/4 inside' }, { H.entry(), H.hunk() })
      H.assert_consistent()
    end)

    it('s marks the hunk and lands on the next one; u brings it back', function()
      H.open('file')
      H.keys('s')
      eq({ 'unseen a/x.lua', '1/3 inside' }, { H.entry(), H.hunk() })
      H.assert_consistent()

      H.focus('list')
      H.keys('gg')
      eq('Seen', H.row())
      H.keys('j')
      eq({ 'seen a/x.lua', '1/1 inside' }, { H.entry(), H.hunk() })
      H.focus('diff')
      H.keys('u')
      -- The seen section drained: stay on the file, now unseen
      eq({ 'unseen a/x.lua', '1/4 inside' }, { H.entry(), H.hunk() })
      H.assert_consistent()
    end)

    for _, layout in ipairs({ 'unified', 'split' }) do
      it('visual s marks the selected hunk (' .. layout .. ')', function()
        H.open('file', { layout = layout })
        -- Unified stacks the hunk's removed and added rows; split pairs them
        H.keys(layout == 'unified' and 'Vjs' or 'Vs')
        eq({ 'unseen a/x.lua', '1/3 inside' }, { H.entry(), H.hunk() })
        local notes = H.notifications()
        H.keys('<Up>')
        H.keys('Vs')
        eq('No hunks in selection', notes[#notes])
        eq({}, errors)
      end)
    end

    it('marks and unmarks single lines of a change in unified layout', function()
      H.open('file')
      local x5 = { { 'x line 5' }, { 'x line 5 CHANGED' } }
      local x20 = { { 'x line 20' }, { 'x line 20 C4' } }

      -- Only the removed line: approve the deletion, not its replacement
      H.keys('Vs')
      eq({ { { 'x line 5' }, {} } }, H.hunks('seen a/x.lua'))
      eq({ {}, { 'x line 5 CHANGED' } }, H.hunks('unseen a/x.lua')[1])

      -- Only the added line: approve the insertion, keeping the old line
      H.select('unseen a/x.lua', 2)
      H.keys('<Down>')
      H.keys('Vs')
      eq({ { { 'x line 5' }, {} }, { {}, { 'x line 20 C4' } } }, H.hunks('seen a/x.lua'))
      eq({ { 'x line 20' }, {} }, H.hunks('unseen a/x.lua')[2])

      -- Unmarking mirrors both
      H.select('seen a/x.lua', 1)
      H.keys('Vu')
      eq({ { {}, { 'x line 20 C4' } } }, H.hunks('seen a/x.lua'))
      eq(x5, H.hunks('unseen a/x.lua')[1])

      H.select('seen a/x.lua', 1)
      H.keys('Vu')
      eq(nil, H.hunks('seen a/x.lua'))
      eq(x20, H.hunks('unseen a/x.lua')[2])
      eq(4, #H.hunks('unseen a/x.lua'))
      eq({}, errors)
    end)

    it('S marks the file and moves to the next unseen file', function()
      H.open('file')
      H.keys('S')
      eq('unseen docs/README.md', H.entry())
      H.assert_consistent()
      H.keys('k')
      eq('seen a/x.lua', H.entry())
    end)

    it('steps into a collapsed folder with j and k', function()
      H.open('file')
      H.focus('list')
      H.keys('j')
      H.keys('<Down>')
      eq('src', H.row())
      H.keys('<CR>')
      H.keys('k')
      eq('unseen docs/README.md', H.entry())
      H.keys('j')
      eq('unseen src/b/y.lua', H.entry())
      H.assert_consistent()

      H.keys('<Up><Up>')
      eq('src', H.row())
      H.keys('<CR>')
      H.keys('<Down>')
      eq('unseen gone.txt', H.entry())
      H.keys('k')
      eq('unseen src/c/z.lua', H.entry())
      H.assert_consistent()
    end)

    it('steps from a section header into its section', function()
      H.open('file')
      H.keys('S')
      H.focus('list')
      H.keys('gg')
      eq('Seen', H.row())
      H.keys('j')
      eq('seen a/x.lua', H.entry())
      H.keys('<Down>')
      eq('Unseen', H.row())
      H.keys('j')
      eq('unseen docs/README.md', H.entry())
      H.keys('<Up>')
      H.keys('<Up>')
      eq('Unseen', H.row())
      H.keys('k')
      eq('seen a/x.lua', H.entry())
      H.assert_consistent()
    end)

    it('leaves a deleted file with k, J and K', function()
      H.open('file')
      H.focus('list')
      for _ = 1, 4 do
        H.keys('j')
      end
      H.focus('diff')
      eq({ 'unseen gone.txt', '1/1 inside' }, { H.entry(), H.hunk() })
      H.keys('k')
      eq('unseen src/c/z.lua', H.entry())
      H.keys('J')
      eq('unseen gone.txt', H.entry())
      H.keys('J')
      eq('unseen img.bin', H.entry())
      H.keys('K')
      eq('unseen gone.txt', H.entry())
      H.keys('K')
      eq('unseen src/c/z.lua', H.entry())
      H.assert_consistent()
    end)

    it('S on the last unseen file wraps to the first, like s', function()
      H.open('file')
      H.focus('list')
      H.keys('k')
      eq('unseen new.txt', H.entry())
      H.keys('S')
      eq('unseen a/x.lua', H.entry())
      H.assert_consistent()
    end)

    it('R re-anchors on the current file, now unseen', function()
      H.open('file')
      H.keys('S')
      H.keys('k')
      eq('seen a/x.lua', H.entry())
      H.keys('R')
      eq({ 'unseen a/x.lua', '1/4 inside' }, { H.entry(), H.hunk() })
      H.assert_consistent()
    end)

    it('reopens with the pane that had focus, however it got there', function()
      H.open('file')
      H.focus('list')
      H.close()
      H.open('file')
      eq(H.screen().scene:get('list').window.win_id, vim.api.nvim_get_current_win())
    end)

    it('keeps the diff on its hunk across a list resize', function()
      H.open('file')
      H.keys('j')
      local screen = H.screen()
      screen:apply_list_width(30)
      H.async(function() screen:finish_list_resize() end)
      eq({ 'unseen a/x.lua', '2/4 inside' }, { H.entry(), H.hunk() })
      eq(30, screen.scene:get('list').window:get_width())
    end)

    it('opens on the current buffer\'s file', function()
      vim.cmd.edit('src/b/y.lua')
      H.open('file')
      eq('unseen src/b/y.lua', H.entry())
      H.assert_consistent()
    end)

    it('opens on the current buffer\'s file from a subdirectory', function()
      vim.cmd.cd('src')
      vim.cmd.edit('b/y.lua')
      H.open('file')
      eq('unseen src/b/y.lua', H.entry())
      H.assert_consistent()
    end)
  end)

  describe('keypress queue', function()
    it('runs every key of a burst, in order', function()
      H.open('file')
      H.keys('jjj')
      eq({ 'unseen a/x.lua', '4/4 inside' }, { H.entry(), H.hunk() })
      -- x.lua's last hunk, then README and y.lua whole
      H.keys('sss')
      eq({ 'unseen src/c/z.lua', '1/1 inside' }, { H.entry(), H.hunk() })
      H.assert_consistent()
      eq({}, errors)
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
      eq({}, errors)
    end)

    it('runs keys pressed just before quit, then quits', function()
      H.open('file')
      H.focus('list')
      H.keys('S<esc>')
      eq(nil, H.screen())
      -- S moved on to README before the quit
      eq(repo .. '/docs/README.md', vim.api.nvim_buf_get_name(0))
      eq({}, errors)

      H.open('file')
      H.focus('list')
      H.keys('gg')
      H.keys('j')
      eq('seen a/x.lua', H.entry())
      eq({}, errors)
    end)

    it('drops the queue when the screen goes away', function()
      H.open('file')
      local screen = H.screen()
      H.keys('jjj', 0)
      H.close()
      eq({}, screen._jobs)
      eq({}, errors)
    end)
  end)

  describe('by commit', function()
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
      eq(vim.list_extend(vim.deepcopy(ORDER), { ORDER[1] }), walk('j', 9))
      eq({ ORDER[1], ORDER[9] }, walk('k', 1))
    end)

    it('J/K in the list jump between commits', function()
      H.open('commit')
      H.focus('list')
      eq({ ORDER[1], ORDER[4], ORDER[6], ORDER[7], ORDER[1] }, walk('J', 4))
      eq({ ORDER[1], ORDER[9], ORDER[6] }, walk('K', 2))
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
        eq({ repo .. '/src/b/y.lua', 3 }, { vim.api.nvim_buf_get_name(0), vim.fn.line('.') })
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
end)
