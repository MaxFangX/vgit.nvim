local loop = require('vgit.core.loop')
local console = require('vgit.core.console')
local screen_manager = require('vgit.ui.screen_manager')
local scene_setting = require('vgit.settings.scene')

local eq = assert.are.same

-- Run fn in a coroutine, as keymap handlers do, and wait for it
local function async(fn)
  local done = false
  loop.coroutine(function()
    fn()
    done = true
  end)()
  assert(vim.wait(10000, function() return done end), 'coroutine did not finish')
end

local FULL = 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n'

describe('ProjectDiffScreen deleted file', function()
  local dir, cwd, errors, notes
  local error = console.error

  -- No optional locks: polling `git status` must not hold index.lock while
  -- the screen stages
  local function git(...)
    local out = vim.fn.system(vim.list_extend({ 'git', '--no-optional-locks', '-C', dir }, { ... }))
    return vim.v.shell_error == 0 and out or nil
  end

  before_each(function()
    cwd = vim.loop.cwd()
    dir = vim.loop.fs_realpath(vim.fn.fnamemodify(vim.fn.tempname(), ':h')) .. '/vgit-pds-' .. vim.loop.hrtime()
    vim.fn.mkdir(dir, 'p')
    git('init', '-q', '-b', 'main')
    git('config', 'user.email', 't@t')
    git('config', 'user.name', 't')
    vim.fn.writefile(vim.split(vim.trim(FULL), '\n'), dir .. '/f.txt')
    git('add', 'f.txt')
    git('commit', '-qm', 'base')
    vim.cmd.cd(dir)
    errors = {}
    console.error = function(msg) errors[#errors + 1] = msg end
  end)

  after_each(function()
    if screen_manager.active_screen then async(screen_manager.destroy_active_screen) end
    vim.cmd('silent! %bwipeout!')
    vim.cmd.cd(cwd)
    vim.fn.delete(dir, 'rf')
    console.error = error
  end)

  -- Open the screen on f.txt's deletion, cursor in the diff on row `row`,
  -- collecting the diff pane's notifications
  local function open(row)
    async(function() screen_manager.create('project_diff_screen') end)
    vim.wait(100)
    local screen = screen_manager.active_screen
    notes = {}
    screen.diff_view.notify = function(view, msg)
      notes[#notes + 1] = vim.trim(msg)
      return getmetatable(view).notify(view, msg)
    end
    screen.scene:get('current'):focus()
    vim.api.nvim_win_set_cursor(0, { row, 0 })
  end

  -- Feed keys, then wait for `done()`: the handlers are debounced and run
  -- git, so how long they take depends on the load
  local function keys(k, done)
    vim.api.nvim_feedkeys(vim.keycode(k), 'x', false)
    assert(vim.wait(10000, done, 20), 'keys did not take effect: ' .. k)
    -- Let the re-render after the git op finish too
    vim.wait(200)
  end

  local function notified(msg)
    return function() return vim.tbl_contains(notes, msg) end
  end

  local function status_is(status, type)
    return function()
      local entry = screen_manager.active_screen.model:get_entry()
      return git('status', '--porcelain') == status and entry ~= nil and entry.type == type
    end
  end

  local REFUSAL = 'Stage or unstage a deleted file whole'

  for _, layout in ipairs({ 'unified', 'split' }) do
    describe(layout, function()
      before_each(function()
        scene_setting:set('diff_preference', layout)
      end)

      it('refuses to stage part of a deletion', function()
        vim.fn.delete(dir .. '/f.txt')
        open(3)
        keys('Vjs', notified(REFUSAL))
        eq({ ' D f.txt\n', FULL }, { git('status', '--porcelain'), git('show', ':f.txt') })
        eq({}, errors)
      end)

      it('refuses to unstage part of a git rm', function()
        git('rm', '-q', 'f.txt')
        open(3)
        keys('Vju', notified(REFUSAL))
        eq({ 'D  f.txt\n', nil }, { git('status', '--porcelain'), git('show', ':f.txt') })
        eq({}, errors)
      end)

      it('stages and unstages a whole deletion', function()
        vim.fn.delete(dir .. '/f.txt')
        open(1)
        keys('s', status_is('D  f.txt\n', 'staged'))

        screen_manager.active_screen.scene:get('current'):focus()
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        keys('u', status_is(' D f.txt\n', 'unstaged'))
        eq({}, errors)
      end)

      it('unstages a whole git rm from a visual selection of all of it', function()
        git('rm', '-q', 'f.txt')
        open(1)
        keys('VGu', status_is(' D f.txt\n', 'unstaged'))
        eq(FULL, git('show', ':f.txt'))
        eq({}, errors)
      end)
    end)
  end
end)
