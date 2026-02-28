local gitcli = require('vgit.git.gitcli')

local git_branch = {}

-- Parse file status lines from git diff --name-status or diff-tree --name-status
local function parse_file_status_lines(lines)
  local files = {}
  for _, line in ipairs(lines) do
    if line ~= '' then
      -- Handle renames: R100\told_name\tnew_name
      local status, old_name, new_name = line:match('^(R%d*)%s+(.+)%s+(.+)$')
      if status then
        files[#files + 1] = {
          status = 'R',
          filename = new_name,
          old_filename = old_name,
        }
      else
        status, old_name = line:match('^(%a)%s+(.+)$')
        if status then
          files[#files + 1] = {
            status = status,
            filename = old_name,
          }
        end
      end
    end
  end
  return files
end

function git_branch.current(reponame)
  if not reponame then return nil, { 'reponame is required' } end

  local result, err = gitcli.run({
    '-C',
    reponame,
    'rev-parse',
    '--abbrev-ref',
    'HEAD',
  })
  if err then return nil, err end
  if not result[1] or result[1] == '' then return nil, { 'Could not determine current branch' } end

  return result[1]
end

-- Get HEAD commit hash
function git_branch.head(reponame)
  if not reponame then return nil, { 'reponame is required' } end

  local result, err = gitcli.run({
    '-C',
    reponame,
    'rev-parse',
    'HEAD',
  })
  if err then return nil, err end
  if not result[1] or result[1] == '' then return nil, { 'Could not determine HEAD' } end

  return result[1]
end

-- Check if a local branch exists
function git_branch.exists(reponame, branch_name)
  if not reponame then return false end
  if not branch_name then return false end

  -- Note: Don't use --quiet here, as gitcli.run detects errors via stderr.
  -- Without --quiet, git outputs to stderr when ref doesn't exist.
  local _, err = gitcli.run({
    '-C',
    reponame,
    'show-ref',
    '--verify',
    'refs/heads/' .. branch_name,
  })

  return err == nil
end

-- Check if a ref exists (can be local branch, remote-tracking, tag, etc.)
function git_branch.ref_exists(reponame, ref)
  if not reponame then return false end
  if not ref then return false end

  local _, err = gitcli.run({
    '-C',
    reponame,
    'rev-parse',
    '--verify',
    ref,
  })

  return err == nil
end

-- Get the merge-base between two commits/branches
function git_branch.merge_base(reponame, ref1, ref2)
  if not reponame then return nil, { 'reponame is required' } end
  if not ref1 then return nil, { 'ref1 is required' } end
  if not ref2 then return nil, { 'ref2 is required' } end

  local result, err = gitcli.run({
    '-C',
    reponame,
    'merge-base',
    ref1,
    ref2,
  })
  if err then return nil, err end
  if not result[1] or result[1] == '' then return nil, { 'Could not find merge-base' } end

  return result[1]
end

-- Track fetch state per repo
local fetch_state = {}  -- { last_success = timestamp, in_progress = bool }

-- Async fetch a remote ref if last fetch was over an hour ago.
-- Shows a notification when done so user knows to reopen the view.
function git_branch.fetch_ref_if_stale(reponame, ref)
  if not reponame or not ref then return end

  local remote, branch = ref:match('^([^/]+)/(.+)$')
  if not remote or not branch then return end

  local state = fetch_state[reponame] or {}
  fetch_state[reponame] = state

  -- Skip if fetch in progress or succeeded within the last hour
  if state.in_progress then return end
  if state.last_success and (os.time() - state.last_success) < 3600 then return end

  state.in_progress = true

  vim.loop.spawn('git', {
    args = { '-C', reponame, 'fetch', remote, branch },
    stdio = { nil, nil, nil },
  }, function(code)
    state.in_progress = false
    if code == 0 then
      state.last_success = os.time()
      vim.schedule(function()
        vim.notify(
          string.format('Fetched %s/%s — reopen to see updated diff', remote, branch),
          vim.log.levels.INFO
        )
      end)
    end
  end)
end

-- Try to detect the default branch (main/master)
-- Prefers origin/<branch> over local branch to avoid issues when local is out of date
function git_branch.detect_base(reponame)
  if not reponame then return nil, { 'reponame is required' } end

  -- First try to detect from origin/HEAD (most reliable)
  local result, _ = gitcli.run({
    '-C',
    reponame,
    'symbolic-ref',
    'refs/remotes/origin/HEAD',
  })

  if result and result[1] then
    -- Result is like "refs/remotes/origin/main"
    local branch = result[1]:match('refs/remotes/origin/(.+)')
    if branch and branch ~= '' then
      return 'origin/' .. branch
    end
  end

  -- Fall back to checking for origin/main or origin/master
  local has_origin_main = git_branch.ref_exists(reponame, 'origin/main')
  local has_origin_master = git_branch.ref_exists(reponame, 'origin/master')

  if has_origin_main and not has_origin_master then
    return 'origin/main'
  end
  if has_origin_master and not has_origin_main then
    return 'origin/master'
  end
  if has_origin_main then
    return 'origin/main'
  end

  -- Last resort: check local branches (for repos without remotes)
  local has_main = git_branch.exists(reponame, 'main')
  local has_master = git_branch.exists(reponame, 'master')

  if has_main and not has_master then
    return 'main'
  end
  if has_master and not has_main then
    return 'master'
  end
  if has_main then
    return 'main'
  end

  -- Could not detect (avoid network operations)
  return nil, { 'Could not detect base branch. Please specify it as an argument.' }
end

-- Get commits between merge-base and HEAD (the PR commits)
function git_branch.commits_in_range(reponame, base_ref, head_ref)
  if not reponame then return nil, { 'reponame is required' } end
  if not base_ref then return nil, { 'base_ref is required' } end

  head_ref = head_ref or 'HEAD'

  local result, err = gitcli.run({
    '-C',
    reponame,
    '--no-pager',
    'log',
    '--reverse',
    '--pretty=format:%H|%h|%s',
    base_ref .. '..' .. head_ref,
  })
  if err then return nil, err end

  local commits = {}
  for _, line in ipairs(result) do
    if line ~= '' then
      local hash, short_hash, message = line:match('([^|]+)|([^|]+)|(.+)')
      if hash then
        commits[#commits + 1] = {
          hash = hash,
          short_hash = short_hash,
          message = message,
        }
      end
    end
  end

  return commits
end

-- Get files changed between two refs
function git_branch.changed_files(reponame, base_ref, head_ref)
  if not reponame then return nil, { 'reponame is required' } end
  if not base_ref then return nil, { 'base_ref is required' } end

  head_ref = head_ref or 'HEAD'

  local result, err = gitcli.run({
    '-C',
    reponame,
    '--no-pager',
    'diff',
    '--name-status',
    base_ref .. '...' .. head_ref,
  })
  if err then return nil, err end

  return parse_file_status_lines(result)
end

-- Get files changed in a specific commit
function git_branch.commit_files(reponame, commit_hash)
  if not reponame then return nil, { 'reponame is required' } end
  if not commit_hash then return nil, { 'commit_hash is required' } end

  local result, err = gitcli.run({
    '-C',
    reponame,
    '--no-pager',
    'diff-tree',
    '--no-commit-id',
    '--name-status',
    '-r',
    commit_hash,
  })
  if err then return nil, err end

  return parse_file_status_lines(result)
end

-- Get files changed for all commits in a range (batched, single git command)
-- Returns a table mapping commit_hash -> files array
function git_branch.all_commit_files(reponame, base_ref, head_ref)
  if not reponame then return nil, { 'reponame is required' } end
  if not base_ref then return nil, { 'base_ref is required' } end

  head_ref = head_ref or 'HEAD'

  -- Use git log with --name-status to get files for all commits in one call
  -- Format: commit hash on one line, then file status lines, then empty line
  local result, err = gitcli.run({
    '-C',
    reponame,
    '--no-pager',
    'log',
    '--reverse',
    '--name-status',
    '--pretty=format:COMMIT:%H',
    base_ref .. '..' .. head_ref,
  })
  if err then return nil, err end

  local commit_files = {}
  local current_hash = nil
  local current_files = {}

  for _, line in ipairs(result) do
    local hash = line:match('^COMMIT:(.+)$')
    if hash then
      -- Save previous commit's files
      if current_hash then
        commit_files[current_hash] = current_files
      end
      current_hash = hash
      current_files = {}
    elseif line ~= '' and current_hash then
      -- Parse file status line
      local status, old_name, new_name = line:match('^(R%d*)%s+(.+)%s+(.+)$')
      if status then
        current_files[#current_files + 1] = {
          status = 'R',
          filename = new_name,
          old_filename = old_name,
        }
      else
        status, old_name = line:match('^(%a)%s+(.+)$')
        if status then
          current_files[#current_files + 1] = {
            status = status,
            filename = old_name,
          }
        end
      end
    end
  end

  -- Save last commit's files
  if current_hash then
    commit_files[current_hash] = current_files
  end

  return commit_files
end

return git_branch
