local event = require('vgit.core.event')
local gitcli = require('vgit.git.gitcli')

local git_repo = {}

-- Cache: directory path -> repo root. Stable within a session; only stale if
-- user runs `git init` in a new location (rare, restart neovim to clear).
local discover_cache = {}

function git_repo.config(reponame)
  if not reponame then return nil, { 'reponame is required' } end
  return gitcli.run({ '-C', reponame, 'config', '--list' })
end

function git_repo.discover(filepath)
  local dirname = (filepath and vim.fn.fnamemodify(filepath, ':p:h')) or vim.loop.cwd()

  local cached = discover_cache[dirname]
  if cached then return cached end

  local result, err = gitcli.run({ '-C', dirname, 'rev-parse', '--show-toplevel' })
  if err then return nil, err end
  if #result == 0 then return nil, {} end

  discover_cache[dirname] = result[1]
  return result[1]
end

-- The absolute git dir. In a linked worktree (or jj workspace) that is the
-- per-worktree dir under the main repo's `.git/worktrees/`.
function git_repo.dirname()
  local reponame, err = git_repo.discover()
  if err then return nil, err end

  local result, git_dir_err = gitcli.run({ '-C', reponame, 'rev-parse', '--absolute-git-dir' })
  if git_dir_err then return nil, git_dir_err end
  if #result == 0 then return nil, {} end

  return result[1]
end

function git_repo.exists(filepath)
  local dirname = (filepath and vim.fn.fnamemodify(filepath, ':p:h')) or vim.loop.cwd()
  local _, err = gitcli.run({ '-C', dirname, 'rev-parse', '--is-inside-git-dir' })

  if err then return false end
  return true
end

function git_repo.has(reponame, filepath, commit)
  if not reponame then return nil, { 'reponame is required' } end
  if not filepath then return nil, { 'filepath is required' } end

  commit = commit or 'HEAD'

  local result, err = gitcli.run({
    '-C',
    reponame,
    '--no-pager',
    'ls-files',
    '--exclude-standard',
    commit,
    filepath,
  })

  if err then return nil, err end
  if #result == 0 then return false end
  return true
end

function git_repo.ignores(reponame, filepath)
  if not reponame then return nil, { 'reponame is required' } end
  if not filepath then return nil, { 'filepath is required' } end

  local result, err = gitcli.run({ '-C', reponame, '--no-pager', 'check-ignore', filepath })

  if err then return nil, err end
  if #result == 0 then return false end
  return true
end

function git_repo.checkout(reponame, name)
  if not reponame then return nil, { 'reponame is required' } end
  if not name then return nil, { 'name is required' } end
  return gitcli.run({ '-C', reponame, '--no-pager', 'checkout', '--quiet', name })
end

function git_repo.reset(reponame, filepath)
  if not reponame then return nil, { 'reponame is required' } end

  local _, err = gitcli.run({
    '-C',
    reponame,
    '--no-pager',
    'checkout',
    '-q',
    '--',
    filepath or '.',
  })
  if err then return nil, err end

  return gitcli.run({
    '-C',
    reponame,
    '--no-pager',
    'clean',
    '-fd',
    '--',
    filepath or '.',
  })
end

function git_repo.clean(reponame, filepath)
  if not reponame then return nil, { 'reponame is required' } end

  return gitcli.run({
    '-C',
    reponame,
    '--no-pager',
    'clean',
    '-fd',
    '--',
    filepath or '.',
  })
end

-- The repo's name: origin's URL basename (`git@h:u/repo.git`,
-- `https://h/u/repo`), or the directory name without one. It names the
-- review state dir, and every review open asks, so it is cached per repo
-- until the git dir changes.
local names = {}
event.custom_on('VGitSync', function(args)
  if args and args.data then names = {} end
end)

function git_repo.get_name(reponame)
  if names[reponame] then return names[reponame] end

  local result = gitcli.run({ '-C', reponame, 'config', '--get', 'remote.origin.url' })
  local url = result and result[1]
  local name = url and (url:gsub('%.git$', '')):match('([^/:]+)$')
  names[reponame] = name or vim.fs.basename(reponame)
  return names[reponame]
end

return git_repo
