-- Helpers for the review screen specs: a throwaway repo, the real screens,
-- keys fed through their mappings. Load with dofile (see review.lua).
local review = dofile('tests/helpers/review.lua')
local loop = require('vgit.core.loop')
local console = require('vgit.core.console')
local screen_manager = require('vgit.ui.screen_manager')
local scene_setting = require('vgit.settings.scene')

local eq = assert.are.same

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

H.run = run
H.make_repo = make_repo

function H.screen()
  return screen_manager.active_screen
end

-- Let scheduled work finish (keymap jobs themselves run as the keys are fed)
function H.settle(ms)
  vim.wait(ms or 30)
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

-- Open the by-`kind` ('file' or 'commit') review against main, or the browse
-- of the range opts.browse
function H.open(kind, opts)
  opts = opts or {}
  scene_setting:set('diff_preference', opts.layout or 'unified')
  local name = string.format('project_%s_by_%s_screen', opts.browse and 'browse' or 'review', kind)
  H.async(function()
    screen_manager.create(name, opts.browse or 'main')
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

-- Give each spec of the enclosing describe a fresh repo as the cwd (H.repo),
-- confirming prompts, collecting console errors (H.errors), and a temp data
-- home. The screen is closed after each spec.
function H.use_repo()
  local cwd
  local input, error = console.input, console.error

  before_each(function()
    console.input = function() return 'y' end
    H.errors = {}
    console.error = function(msg)
      H.errors[#H.errors + 1] = msg
    end
    cwd = vim.loop.cwd()
    H.repo = make_repo()
    vim.cmd.cd(H.repo)
  end)

  after_each(function()
    H.close()
    vim.cmd('silent! %bwipeout!')
    vim.cmd.cd(cwd)
    vim.fn.delete(H.repo, 'rf')
    console.input, console.error = input, error
  end)

  -- After the hooks above, so the screen saves into the temp dir before it goes
  review.use_temp_homes()
end

-- Walk `n` presses of `keys`, collecting the entry after each
function H.walk(keys, n)
  local seen = { H.entry() }
  for _ = 1, n do
    H.keys(keys)
    H.assert_consistent()
    seen[#seen + 1] = H.entry()
  end
  return seen
end

return H
