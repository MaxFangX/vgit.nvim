local async = require('plenary.async.tests')
local loop = require('vgit.core.loop')
local git_show = require('vgit.git.git_show')
local git_setting = require('vgit.settings.git')

local eq = assert.are.same

local function sh(dir, cmd)
  if vim.in_fast_event() then loop.free_textlock() end
  vim.fn.system(string.format('cd %s && %s', vim.fn.shellescape(dir), cmd))
  assert(vim.v.shell_error == 0, 'command failed: ' .. cmd)
end

local function make_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  sh(dir, 'git init -q -b master && git config user.email t@t.co && git config user.name t')
  sh(dir, 'printf "a\\nb\\n" > f.txt && mkdir d && printf "x" > d/x.txt && printf "" > empty.txt')
  sh(dir, 'git add -A && git commit -q -m A')
  -- A gitlink, as a submodule bump records it
  sh(dir, 'git update-index --add --cacheinfo 160000,' .. string.rep('1', 40) .. ',sub && git commit -q -m B')
  return dir
end

local function cleanup(dir)
  loop.free_textlock()
  vim.fn.delete(dir, 'rf')
end

async.describe('git_show.lines_batch:', function()
  async.it('returns blob lines and treats non-blobs as missing', function()
    local dir = make_repo()
    local specs = { 'HEAD:f.txt', 'HEAD:d', 'HEAD:sub', 'HEAD:nope', 'HEAD:empty.txt' }
    local results, err = git_show.lines_batch(dir, specs)
    eq(err, nil)
    eq(results, {
      { lines = { 'a', 'b' } },
      { missing = true },
      { missing = true },
      { missing = true },
      { lines = {} },
    })
    cleanup(dir)
  end)

  async.it('fails, rather than reporting every object missing, when git fails', function()
    local results, err = git_show.lines_batch('/nonexistent/vgit-repo', { 'HEAD:f.txt' })
    eq(results, nil)
    assert.is_true(#err > 0)
  end)

  async.it('fails when git cannot be spawned', function()
    local dir = make_repo()
    local cmd = git_setting:get('cmd')
    git_setting:set('cmd', 'vgit-no-such-git')
    local results, err = git_show.lines_batch(dir, { 'HEAD:f.txt' })
    git_setting:set('cmd', cmd)
    eq(results, nil)
    assert.is_true(#err > 0)
    cleanup(dir)
  end)
end)

async.describe('git_show.lines_batch sharing:', function()
  async.it('parses each blob once, sharing its lines across requests', function()
    local dir = make_repo()
    sh(dir, 'cp f.txt g.txt && git add g.txt && git commit -q -m C')
    local results = git_show.lines_batch(dir, { 'HEAD~1:f.txt', 'HEAD:f.txt', 'HEAD:g.txt' })
    assert.is_true(results[1].lines == results[2].lines)
    assert.is_true(results[2].lines == results[3].lines)
    cleanup(dir)
  end)
end)
