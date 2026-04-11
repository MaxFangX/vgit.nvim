local gitcli = require('vgit.git.gitcli')

local git_show = {}

function git_show.lines(reponame, filepath, commit_hash)
  if not reponame then return nil, { 'reponame is required' } end
  commit_hash = commit_hash or ''
  return gitcli.run({
    '-C',
    reponame,
    'show',
    string.format('%s:%s', commit_hash, filepath),
  })
end

function git_show.commit_message(reponame, commit_hash)
  if not reponame then return nil, { 'reponame is required' } end
  if not commit_hash then return nil, { 'commit_hash is required' } end
  return gitcli.run({
    '-C',
    reponame,
    'show',
    '-s',
    '--format=%B',
    commit_hash,
  })
end

return git_show
