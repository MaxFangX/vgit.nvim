local jj = require('vgit.git.jj')
local gitcli = require('vgit.git.gitcli')
local utils = require('vgit.core.utils')

local git_branch = {}

-- Read a file's first line, or nil. Uses io.open rather than fs.read_file
-- (vim.fn.readfile) so it's safe in fast event contexts, where this may run.
local function read_first_line(path)
  local fd = io.open(path, 'r')
  if not fd then return nil end
  local line = fd:read('*l')
  fd:close()
  return line
end

-- Resolve a repo's git dir. For a normal repo this is `<reponame>/.git`; for a
-- linked worktree `<reponame>/.git` is a file ("gitdir: <path>") pointing at the
-- main repo's `.git/worktrees/<name>/`, where that worktree's state actually lives.
local function resolve_git_dir(reponame)
  local dotgit = reponame .. '/.git'

  -- A regular file (not a dir) means a linked worktree; follow its gitdir pointer.
  local stat = vim.loop.fs_stat(dotgit)
  if stat and stat.type == 'file' then
    local gitdir = (read_first_line(dotgit) or ''):match('^gitdir:%s*(.-)%s*$')
    if gitdir and gitdir ~= '' then
      if not gitdir:match('^/') then gitdir = reponame .. '/' .. gitdir end
      return gitdir
    end
  end

  return dotgit
end

-- Read the original branch name during a rebase.
-- Interactive rebase stores in rebase-merge/, regular rebase in rebase-apply/.
-- Resolving the git dir first (rather than hand-building `<reponame>/.git/...`)
-- keeps this correct in linked worktrees, where that literal path doesn't exist
-- and we'd otherwise fall back to a detached "HEAD" as the persistence key.
local function read_rebase_head_name(reponame)
  local git_dir = resolve_git_dir(reponame)

  for _, subpath in ipairs({ 'rebase-merge/head-name', 'rebase-apply/head-name' }) do
    -- Content is like "refs/heads/feature/my-branch"
    local branch = (read_first_line(git_dir .. '/' .. subpath) or ''):match('refs/heads/(.+)')
    if branch then return branch end
  end

  return nil
end

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
          filepath = new_name,
          old_filepath = old_name,
        }
      else
        status, old_name = line:match('^(%a)%s+(.+)$')
        if status then
          files[#files + 1] = {
            status = status,
            filepath = old_name,
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

-- Local branches to ignore when inferring HEAD's branch: trunk (we want the
-- feature branch, not the base) and `backup/*` snapshots (e.g. from a backup
-- alias), which otherwise tie with and hijack the real branch.
local function is_ignored_branch(name)
  return name == 'master' or name == 'main' or name:match('^backup/') ~= nil
end

-- Symmetric distance (commits reachable from one side but not the other) ranks a
-- branch whether it's ahead of, behind, or diverged from HEAD; runs in parallel.
-- Assumes `candidates` is sorted, so ties break by name and the key stays stable.
local function nearest_by_distance(reponame, candidates)
  if #candidates == 1 then return candidates[1] end

  local commands = {}
  for _, name in ipairs(candidates) do
    commands[#commands + 1] = { '-C', reponame, 'rev-list', '--count', name .. '...HEAD' }
  end
  local results = gitcli.run_parallel(commands)

  local best, best_dist
  for i, name in ipairs(candidates) do
    local out = results[i] and results[i].result
    local dist = out and tonumber(out[1]) or math.huge
    if not best_dist or dist < best_dist then
      best, best_dist = name, dist
    end
  end
  return best
end

-- Resolve HEAD's branch from the live bookmarks. In a jj repo git HEAD
-- is the working copy's parent, which roams as you rewrite history: it can sit
-- behind the branch bookmark (which doesn't auto-advance with new work), ahead of
-- it, or — right after a mid-stack amend, before jj re-exports the bookmark — on a
-- sibling that has *diverged* from it. Geometry can't tell those apart from stale
-- unrelated branches (or merged bookmarks parked on the trunk, which inherit the
-- trunk's proximity), so candidates are ranked by stack identity instead: overlap
-- of commit subjects past the trunk — the same rewrite-stable identity the review
-- marks are keyed by. Zero overlap disqualifies; nil means no branch claims
-- HEAD's stack. Ties (e.g. a stack and its pristine copy) break by symmetric
-- distance, then by sorted name so the key stays stable.
function git_branch.branch_for_head(reponame)
  local refs = gitcli.run({
    '-C', reponame, 'for-each-ref', '--format=%(refname:short)', 'refs/heads/',
  })

  local candidates = {}
  for _, name in ipairs(refs or {}) do
    if name ~= '' and not is_ignored_branch(name) then
      candidates[#candidates + 1] = name
    end
  end

  if #candidates == 0 then return nil end
  table.sort(candidates)

  -- The trunk anchors stack identity (subjects past it); without one there is
  -- no stack notion to compare, so fall back to pure distance.
  local trunk = (git_branch.exists(reponame, 'main') and 'main')
    or (git_branch.exists(reponame, 'master') and 'master')
  if not trunk then return nearest_by_distance(reponame, candidates) end

  local head_subjects = {}
  local head_lines = gitcli.run({ '-C', reponame, '--no-pager', 'log', '--format=%s', trunk .. '..HEAD' })
  for _, line in ipairs(head_lines or {}) do
    if line ~= '' then head_subjects[line] = true end
  end

  local commands = {}
  for _, name in ipairs(candidates) do
    commands[#commands + 1] = { '-C', reponame, '--no-pager', 'log', '--format=%s', trunk .. '..' .. name }
  end
  local results = gitcli.run_parallel(commands)

  local best, best_overlap = {}, 0
  for i, name in ipairs(candidates) do
    local overlap, counted = 0, {}
    for _, line in ipairs((results[i] and results[i].result) or {}) do
      if line ~= '' and head_subjects[line] and not counted[line] then
        counted[line] = true
        overlap = overlap + 1
      end
    end
    if overlap > best_overlap then
      best, best_overlap = { name }, overlap
    elseif overlap == best_overlap and overlap > 0 then
      best[#best + 1] = name
    end
  end

  if best_overlap == 0 then return nil end
  return nearest_by_distance(reponame, best)
end

-- Set of FNV-1a subject hashes for the commits in `base_ref..HEAD`. Subjects
-- survive rebases (unlike commit hashes), and this hash matches the one review
-- marks are keyed by — so callers can identify which stored review covers HEAD's
-- current commits regardless of where any bookmark sits.
function git_branch.head_subject_hashes(reponame, base_ref)
  local subjects = {}
  local commits = git_branch.commits_in_range(reponame, base_ref, 'HEAD')
  for _, commit in ipairs(commits or {}) do
    subjects[utils.str.fnv1a(vim.trim(commit.message))] = true
  end
  return subjects
end

-- Get the original branch name, even when HEAD isn't on a branch ref.
-- Use this for persistence keys that should stay stable across rebases and in
-- jj-colocated repos (where git HEAD sits detached within the branch's stack).
-- `resolve_detached()` (optional) is consulted only for a detached jj HEAD; it
-- returns a branch name (e.g. by matching HEAD's commits to a stored review) or
-- nil to fall through to the topology-based `branch_for_head`.
function git_branch.current_persistent(reponame, resolve_detached)
  if not reponame then return nil, { 'reponame is required' } end

  -- Check for rebase-in-progress first (HEAD is detached during rebases)
  local rebase_branch = read_rebase_head_name(reponame)
  if rebase_branch then return rebase_branch end

  local branch, err = git_branch.current(reponame)
  if err then return nil, err end

  -- Detached HEAD. In a jj-colocated repo this is the normal working state (git
  -- HEAD sits at the working copy's parent), so recover the branch instead of
  -- collapsing to the literal "HEAD" (a cross-branch dumping ground). Gated on jj
  -- so a deliberate detached checkout in a plain-git repo still keys as "HEAD".
  --
  -- Live bookmarks (`branch_for_head`) outrank the stored-review resolver:
  -- with stacked branches, a substack's reviewed subjects all sit inside the
  -- superstack, so content overlap alone would key the superstack to the
  -- substack's review — only topology can tell "this stack, rebased" from "a
  -- superstack built on it". Both rank by the same subject identity, so a
  -- lagging or diverged bookmark still wins whenever it claims HEAD's stack;
  -- stored reviews remain the fallback for deleted or out-of-reach bookmarks.
  if branch == 'HEAD' and jj.is_repo(reponame) then
    local resolved = git_branch.branch_for_head(reponame)
      or (resolve_detached and resolve_detached())
    if resolved then return resolved end
    -- HEAD at/behind the trunk means trunk work (reviewed against origin);
    -- `branch_for_head` ignores trunk branches, so check here. HEAD *past*
    -- the trunk with no feature branch in reach is trunk work too: jj
    -- bookmarks don't auto-advance, so unpushed trunk commits leave the
    -- bookmark behind HEAD.
    return git_branch.trunk_containing_head(reponame)
      or git_branch.trunk_behind_head(reponame)
      or branch
  end

  return branch
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
-- Shows a notification only if the ref was actually updated.
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

  -- Get current SHA before fetch
  local old_sha_chunks = {}
  local sha_stdout = vim.loop.new_pipe(false)
  vim.loop.spawn('git', {
    args = { '-C', reponame, 'rev-parse', ref },
    stdio = { nil, sha_stdout, nil },
  }, function()
    sha_stdout:read_stop()
    if not sha_stdout:is_closing() then sha_stdout:close() end

    local old_sha = table.concat(old_sha_chunks):gsub('%s+', '')

    -- Now fetch
    vim.loop.spawn('git', {
      args = { '-C', reponame, 'fetch', remote, branch },
      stdio = { nil, nil, nil },
    }, function(code)
      state.in_progress = false
      if code == 0 then
        state.last_success = os.time()

        -- Get new SHA after fetch
        local new_sha_chunks = {}
        local new_sha_stdout = vim.loop.new_pipe(false)
        vim.loop.spawn('git', {
          args = { '-C', reponame, 'rev-parse', ref },
          stdio = { nil, new_sha_stdout, nil },
        }, function()
          new_sha_stdout:read_stop()
          if not new_sha_stdout:is_closing() then new_sha_stdout:close() end

          local new_sha = table.concat(new_sha_chunks):gsub('%s+', '')

          -- Only notify if ref actually changed
          if old_sha ~= new_sha then
            vim.schedule(function()
              vim.notify(
                string.format('Fetched %s/%s — reopen to see updated diff', remote, branch),
                vim.log.levels.INFO
              )
            end)
          end
        end)
        new_sha_stdout:read_start(function(_, chunk)
          if chunk then new_sha_chunks[#new_sha_chunks + 1] = chunk end
        end)
      end
    end)
  end)
  sha_stdout:read_start(function(_, chunk)
    if chunk then old_sha_chunks[#old_sha_chunks + 1] = chunk end
  end)
end

-- The local trunk branch (main/master) that HEAD sits on — i.e. HEAD is at or
-- behind its tip. This identifies "working on the trunk itself", including in
-- jj-colocated repos where HEAD is detached at the working-copy parent, as
-- opposed to a feature branch with commits past the trunk (a descendant HEAD
-- returns nil; see `trunk_behind_head` for the descendant case).
function git_branch.trunk_containing_head(reponame)
  local head = git_branch.head(reponame)
  if not head then return nil end

  for _, trunk in ipairs({ 'main', 'master' }) do
    -- HEAD is ancestor-or-equal of the trunk iff merge-base(trunk, HEAD) == HEAD
    if git_branch.exists(reponame, trunk) and git_branch.merge_base(reponame, trunk, 'HEAD') == head then
      return trunk
    end
  end

  return nil
end

-- Resolve a ref to its commit hash, or nil.
local function rev_parse(reponame, ref)
  local result, err = gitcli.run({ '-C', reponame, 'rev-parse', '--verify', ref })
  if err then return nil end
  return result[1]
end

-- The local trunk branch (main/master) sitting strictly behind HEAD, when the
-- commits past it are unclaimed trunk work rather than a feature branch. This
-- is the jj-colocated shape of "on the trunk with unpushed commits": bookmarks
-- don't auto-advance, so committing on the trunk leaves HEAD ahead of the
-- trunk bookmark, with no feature branch anywhere near HEAD. Guards:
--   - jj repos only: in plain git a detached descendant HEAD is a deliberate
--     checkout (e.g. reviewing a merged PR), not everyday trunk work.
--   - origin/<trunk> must be at/behind <trunk>: a local trunk rewound behind
--     its remote means a historical review, not trunk work.
--   - no feature branch may claim HEAD's stack (`branch_for_head`, which
--     matches by shared commit subjects — stale unrelated bookmarks don't
--     block the trunk fallback).
function git_branch.trunk_behind_head(reponame)
  if not jj.is_repo(reponame) then return nil end

  local head = git_branch.head(reponame)
  if not head then return nil end

  for _, trunk in ipairs({ 'main', 'master' }) do
    local tip = rev_parse(reponame, 'refs/heads/' .. trunk)
    local behind = tip and tip ~= head and git_branch.merge_base(reponame, trunk, 'HEAD') == tip
    local origin_tip = behind and rev_parse(reponame, 'refs/remotes/origin/' .. trunk) or nil
    if origin_tip and git_branch.merge_base(reponame, 'origin/' .. trunk, trunk) == origin_tip then
      return git_branch.branch_for_head(reponame) == nil and trunk or nil
    end
  end

  return nil
end

-- Try to detect the default branch (main/master)
-- Prefers a local main/master branch over origin/<branch>. This makes it easy
-- to review a PR *after* it has merged: just point local master at the PR's
-- pre-merge base (`git branch -f master <sha>`) and reopen the review.
-- Exception: when HEAD sits on the trunk itself — at/behind its tip (where
-- the local trunk would diff as empty) or ahead of a lagging jj bookmark —
-- the origin counterpart is used: reviewing unpushed trunk work.
function git_branch.detect_base(reponame)
  if not reponame then return nil, { 'reponame is required' } end

  -- On the trunk itself: review against origin so unpushed commits show up
  local trunk = git_branch.trunk_containing_head(reponame) or git_branch.trunk_behind_head(reponame)
  if trunk and git_branch.ref_exists(reponame, 'origin/' .. trunk) then
    return 'origin/' .. trunk
  end

  -- Prefer a local main/master branch (easy to point wherever you want)
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

  -- Fall back to origin/HEAD (most reliable remote default)
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
          filepath = new_name,
          old_filepath = old_name,
        }
      else
        status, old_name = line:match('^(%a)%s+(.+)$')
        if status then
          current_files[#current_files + 1] = {
            status = status,
            filepath = old_name,
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
