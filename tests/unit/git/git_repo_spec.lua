local async = require('plenary.async.tests')
local git_repo = require('vgit.git.git_repo')

local eq = assert.are.same

async.describe('repo:', function()
  async.it('should be able to retrieve current repo path', function()
    local repo, err = git_repo.discover()
    assert(not err)
    eq(repo, vim.loop.cwd())
  end)

  async.it('returns true if repo exists', function()
    local exists, err = git_repo.exists()
    assert(not err)
    eq(exists, true)
  end)

  async.it('should be able to discover a repository', function()
    local filepath = vim.loop.cwd() .. '/' .. 'README.md'
    local repo, err = git_repo.discover(filepath)
    assert(not err)
    eq(repo, vim.loop.cwd())
  end)

  async.it('should be true if a file exists in a repository', function()
    local filepath = vim.loop.cwd() .. '/' .. 'README.md'
    local exists, err = git_repo.exists(filepath)
    assert(not err)
    eq(exists, true)
  end)
end)

async.describe('dirname:', function()
  async.it('is the absolute per-worktree git dir in a linked worktree', function()
    local loop = require('vgit.core.loop')
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/main', 'p')
    vim.fn.system(string.format(
      'cd %s/main && git init -q -b master && git -c user.email=t@t.co -c user.name=t commit -q --allow-empty -m A'
        .. ' && git worktree add -q ../wt',
      root
    ))
    local cwd = vim.loop.cwd()
    vim.cmd.cd(root .. '/wt')

    local dirname = git_repo.dirname()
    loop.free_textlock()
    vim.cmd.cd(cwd)
    eq(dirname, vim.loop.fs_realpath(root .. '/main/.git/worktrees/wt'))
    vim.fn.delete(root, 'rf')
  end)
end)

async.describe('get_name:', function()
  async.it('names a repo by its origin URL, else its directory', function()
    local loop = require('vgit.core.loop')
    for url, name in pairs({
      ['git@github.com:user/api.git'] = 'api',
      ['git@host:api.git'] = 'api',
      ['https://github.com/user/api.git'] = 'api',
      ['https://github.com/user/api'] = 'api',
      ['/srv/git/api.git'] = 'api',
    }) do
      loop.free_textlock()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      vim.fn.system(string.format('cd %s && git init -q && git remote add origin %s', dir, url))
      eq(git_repo.get_name(dir), name)
      loop.free_textlock()
      vim.fn.delete(dir, 'rf')
    end

    local dir = vim.fn.tempname() .. '/plain-repo'
    vim.fn.mkdir(dir, 'p')
    vim.fn.system(string.format('cd %s && git init -q', dir))
    eq(git_repo.get_name(dir), 'plain-repo')
    loop.free_textlock()
    vim.fn.delete(dir, 'rf')
  end)
end)
