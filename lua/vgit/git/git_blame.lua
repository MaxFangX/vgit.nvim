local gitcli = require('vgit.git.gitcli')
local GitBlame = require('vgit.git.GitBlame')

local git_blame = {}

function git_blame.list(reponame, filepath, commit)
  if not reponame then return nil, { 'reponame is required' } end
  if not filepath then return nil, { 'filepath is required' } end

  commit = commit or 'HEAD'

  local lines, err = gitcli.run({
    '-C',
    reponame,
    'blame',
    '--line-porcelain',
    '--',
    filepath,
    commit,
  })

  if err then return nil, err end

  local blames = {}
  local blame_info = {}
  for i = 1, #lines do
    local line = lines[i]

    if string.byte(line:sub(1, 3)) ~= 9 then
      table.insert(blame_info, line)
    else
      blames[#blames + 1] = GitBlame(blame_info)
      blame_info = {}
    end
  end

  return blames
end

function git_blame.get(reponame, filepath, lnum)
  if not reponame then return nil, { 'reponame is required' } end
  if not filepath then return nil, { 'filepath is required' } end
  if not lnum then return nil, { 'lnum is required' } end

  local blame_info, err = gitcli.run({
    '-C',
    reponame,
    'blame',
    '-L',
    string.format('%s,+1', lnum),
    '--line-porcelain',
    '--',
    filepath,
  })

  if err then return nil, err end

  return GitBlame(blame_info)
end

return git_blame
