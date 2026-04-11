local fs = require('vgit.core.fs')
local gitcli = require('vgit.git.gitcli')
local GitPatch = require('vgit.git.GitPatch')

local git_stager = {}

function git_stager.stage(reponame, filepath)
  if not reponame then return nil, { 'reponame is required' } end

  return gitcli.run({
    '-C',
    reponame,
    '--no-pager',
    'add',
    '--',
    filepath or '.',
  })
end

function git_stager.unstage(reponame, filepath)
  if not reponame then return nil, { 'reponame is required' } end

  return gitcli.run({
    '-C',
    reponame,
    'reset',
    '-q',
    'HEAD',
    '--',
    filepath or '.',
  })
end

function git_stager.stage_hunk(reponame, filepath, hunk)
  if not reponame then return nil, { 'reponame is required' } end
  if not filepath then return nil, { 'filepath is required' } end
  if not hunk then return nil, { 'hunk is required' } end

  local patch = GitPatch(filepath, hunk)
  local patch_filepath = fs.tmpname()

  fs.write_file(patch_filepath, patch)

  local _, err = gitcli.run({
    '-C',
    reponame,
    '--no-pager',
    'apply',
    '--cached',
    '--whitespace=nowarn',
    '--unidiff-zero',
    patch_filepath,
  })

  fs.remove_file(patch_filepath)

  return nil, err
end

function git_stager.unstage_hunk(reponame, filepath, hunk)
  if not reponame then return nil, { 'reponame is required' } end
  if not filepath then return nil, { 'filepath is required' } end
  if not hunk then return nil, { 'hunk is required' } end

  local patch = GitPatch(filepath, hunk)
  local patch_filepath = fs.tmpname()

  fs.write_file(patch_filepath, patch)

  local _, err = gitcli.run({
    '-C',
    reponame,
    '--no-pager',
    'apply',
    '--reverse',
    '--cached',
    '--whitespace=nowarn',
    '--unidiff-zero',
    patch_filepath,
  })

  fs.remove_file(patch_filepath)

  return nil, err
end

-- Reset (discard) a hunk in the working directory
function git_stager.reset_hunk(reponame, filepath, hunk)
  if not reponame then return nil, { 'reponame is required' } end
  if not filepath then return nil, { 'filepath is required' } end
  if not hunk then return nil, { 'hunk is required' } end

  local patch = GitPatch(filepath, hunk)
  local patch_filepath = fs.tmpname()

  fs.write_file(patch_filepath, patch)

  -- Apply the patch in reverse to the working directory (not staged)
  local _, err = gitcli.run({
    '-C',
    reponame,
    '--no-pager',
    'apply',
    '--reverse',
    '--whitespace=nowarn',
    '--unidiff-zero',
    patch_filepath,
  })

  fs.remove_file(patch_filepath)

  return nil, err
end

return git_stager
