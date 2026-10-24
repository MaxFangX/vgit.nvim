local loop = require('vgit.core.loop')
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

function H.keys(keys, ms)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'x', false)
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

-- The list cursor and the diff pane agree on one entry
function H.assert_consistent()
  eq(H.entry(), H.row())
end

describe('ProjectReviewScreen', function()
  local repo, cwd, xdg

  before_each(function()
    cwd = vim.loop.cwd()
    xdg = vim.env.XDG_DATA_HOME
    vim.env.XDG_DATA_HOME = vim.fn.tempname()
    repo = make_repo()
    vim.cmd.cd(repo)
  end)

  after_each(function()
    H.close()
    vim.cmd('silent! %bwipeout!')
    vim.cmd.cd(cwd)
    vim.env.XDG_DATA_HOME = xdg
    vim.fn.delete(repo, 'rf')
  end)

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

    it('S marks the file and moves to the next unseen file', function()
      H.open('file')
      H.keys('S')
      eq('unseen docs/README.md', H.entry())
      H.assert_consistent()
      H.keys('k')
      eq('seen a/x.lua', H.entry())
    end)

    it('opens on the current buffer\'s file', function()
      vim.cmd.edit('src/b/y.lua')
      H.open('file')
      eq('unseen src/b/y.lua', H.entry())
      H.assert_consistent()
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
