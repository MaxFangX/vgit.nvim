local jj = require('vgit.git.jj')
local loop = require('vgit.core.loop')
local console = require('vgit.core.console')
local gitcli = require('vgit.git.gitcli')
local utils = require('vgit.core.utils')
local event = require('vgit.core.event')

local git_branch = {}

-- Read a file's first line, or nil. This may run in fast event contexts,
-- where fs.read_file (vim.fn.readfile) isn't allowed, so it uses io.open.
local function read_first_line(path)
  local fd = io.open(path, 'r')
  if not fd then return nil end
  local line = fd:read('*l')
  fd:close()
  return line
end

-- Resolve a repo's git dir: `<reponame>/.git`, or in a linked worktree, the
-- dir that file points to ("gitdir: <path>") under the main repo's
-- `.git/worktrees/`.
local function resolve_git_dir(reponame)
  local dotgit = reponame .. '/.git'

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

-- Read the original branch name during a rebase. Git keeps it under
-- rebase-merge/ or rebase-apply/, depending on the rebase backend.
local function read_rebase_head_name(reponame)
  local git_dir = resolve_git_dir(reponame)

  for _, subpath in ipairs({ 'rebase-merge/head-name', 'rebase-apply/head-name' }) do
    -- Content is like "refs/heads/feature/my-branch"
    local branch = (read_first_line(git_dir .. '/' .. subpath) or ''):match('refs/heads/(.+)')
    if branch then return branch end
  end

  return nil
end

-- Parse `--name-status -z` records from NUL-split `tokens` into `files`,
-- starting at index `i`. Returns the index of the first token that isn't a
-- status. In `git log` output, a newline precedes the first status after a
-- commit's header. jj conflict artifacts aren't reviewable changes and can
-- number in the thousands, so they are dropped.
local function parse_name_status(tokens, i, files)
  while tokens[i] do
    local status = tokens[i]:match('^\n?(%u)%d*$')
    if not status then break end

    local file
    if status == 'R' or status == 'C' then
      file = { status = status, old_filepath = tokens[i + 1], filepath = tokens[i + 2] }
      i = i + 3
    else
      file = { status = status, filepath = tokens[i + 1] }
      i = i + 2
    end
    if not jj.is_conflict_artifact(file.filepath) then files[#files + 1] = file end
  end
  return i
end

local function split_nul(output)
  return vim.split(output, '\0', { plain = true })
end

-- Resolve a ref to its commit hash, or nil.
local function rev_parse(reponame, ref)
  local result, err = gitcli.run({ '-C', reponame, 'rev-parse', '--verify', ref })
  if err then return nil end
  return result[1]
end

local function merge_base(reponame, ref1, ref2)
  local result, err = gitcli.run({ '-C', reponame, 'merge-base', ref1, ref2 })
  if err then return nil, err end
  if not result[1] or result[1] == '' then return nil, { 'Could not find merge-base' } end

  return result[1]
end

local TRUNKS = { 'main', 'master' }

-- Matches ReviewModel.branch_by_subjects's threshold
local MIN_SUBJECT_OVERLAP = 2

-- Local branches that never claim HEAD: the trunk, which is the base rather
-- than the feature branch, and `backup/*` snapshots, which would otherwise tie
-- with the real branch.
local function is_ignored_branch(name)
  return vim.tbl_contains(TRUNKS, name) or name:match('^backup/') ~= nil
end

-- HEAD's hash and symbolic name ('HEAD' when detached), in one process.
local function read_head(reponame)
  local result, err = gitcli.run({ '-C', reponame, 'rev-parse', 'HEAD', '--abbrev-ref', 'HEAD' })
  if err then return nil, err end
  if not result[1] or not result[2] then return nil, { 'Could not determine HEAD' } end
  return result[1], result[2]
end

-- Every local and remote-tracking branch tip, in one process: `heads` and
-- `remotes` map short names to hashes, `origin_head` is origin/HEAD's target
-- ('origin/main'), and `output` is the raw listing (for the fingerprint).
local function read_refs(reponame)
  local output, err = gitcli.run({
    '-C', reponame, 'for-each-ref', '--format=%(objectname) %(refname) %(symref)', 'refs/heads', 'refs/remotes',
  })
  if err then return nil, err end

  local refs = { heads = {}, remotes = {}, output = output }
  for _, line in ipairs(output) do
    local hash, refname, symref = line:match('^(%x+) (%S+) ?(.*)$')
    local head = refname and refname:match('^refs/heads/(.+)$')
    local remote = refname and refname:match('^refs/remotes/(.+)$')
    if head then
      refs.heads[head] = hash
    elseif remote == 'origin/HEAD' then
      refs.origin_head = symref:match('^refs/remotes/(.+)$')
    elseif remote then
      refs.remotes[remote] = hash
    end
  end
  return refs
end

-- The candidate nearest HEAD by symmetric distance (commits reachable from one
-- side but not the other), which ranks a branch whether it is ahead of, behind,
-- or diverged from HEAD. `candidates` must be sorted, so ties break by name and
-- the result stays stable.
local function nearest_by_distance(reponame, head, candidates)
  if #candidates == 1 then return candidates[1] end

  local commands = {}
  for _, name in ipairs(candidates) do
    commands[#commands + 1] = { '-C', reponame, 'rev-list', '--count', name .. '...' .. head }
  end
  local results = gitcli.run_parallel(commands)

  local best, best_dist
  for i, name in ipairs(candidates) do
    local out = results[i].result
    local dist = out and tonumber(out[1]) or math.huge
    if not best_dist or dist < best_dist then
      best, best_dist = name, dist
    end
  end
  return best
end

-- The live bookmark claiming HEAD's stack, or nil.
--
-- In a jj repo, git HEAD is the working copy's parent, which moves as history
-- is rewritten. It can sit behind the branch bookmark; ahead of it, since
-- bookmarks don't advance with new work; or, right after a mid-stack amend and
-- before jj re-exports the bookmark, on a sibling that diverged from it.
-- Distance can't tell those apart from stale unrelated branches, or from merged
-- bookmarks parked on the trunk. So candidates are ranked by stack identity
-- instead: the commit subjects past the trunk they share with HEAD, which
-- record keys also use because they survive rewrites. A candidate qualifies by
-- sharing a commit with HEAD past the trunk, or by meeting the stored-review
-- resolver's subject threshold, so one shared generic subject like "fmt" can't
-- let a stale bookmark claim a new stack. Ties, e.g. a stack and its pristine
-- copy, break by distance.
local function claim_head(reponame, head, refs)
  local candidates = {}
  for name in pairs(refs.heads) do
    if not is_ignored_branch(name) then candidates[#candidates + 1] = name end
  end
  if #candidates == 0 then return nil end
  table.sort(candidates)

  -- Stack identity is the subjects past the trunk, so without a trunk fall
  -- back to distance.
  local trunk = (refs.heads.main and 'main') or (refs.heads.master and 'master')
  if not trunk then return nearest_by_distance(reponame, head, candidates) end

  -- Commits past the trunk, as `<hash> <subject>` lines
  local function log_args(ref)
    return { '-C', reponame, '--no-pager', 'log', '--format=%H %s', trunk .. '..' .. ref }
  end

  local head_hashes, head_subjects, head_count = {}, {}, 0
  for _, line in ipairs(gitcli.run(log_args(head)) or {}) do
    local hash, subject = line:match('^(%x+) (.*)$')
    if hash then
      head_hashes[hash] = true
      if subject ~= '' and not head_subjects[subject] then
        head_subjects[subject] = true
        head_count = head_count + 1
      end
    end
  end

  local commands = {}
  for _, name in ipairs(candidates) do
    commands[#commands + 1] = log_args(name)
  end
  local results = gitcli.run_parallel(commands)

  local best, best_overlap = {}, 0
  for i, name in ipairs(candidates) do
    local overlap, subjects, shares_commit, counted = 0, 0, false, {}
    for _, line in ipairs(results[i].result or {}) do
      local hash, subject = line:match('^(%x+) (.*)$')
      if hash then
        shares_commit = shares_commit or head_hashes[hash] == true
        if subject ~= '' and not counted[subject] then
          counted[subject] = true
          subjects = subjects + 1
          if head_subjects[subject] then overlap = overlap + 1 end
        end
      end
    end

    local qualifies = shares_commit
      or overlap >= MIN_SUBJECT_OVERLAP
      or (overlap > 0 and overlap == subjects and 2 * overlap >= head_count)
    local score = qualifies and math.max(overlap, 1) or 0
    if score > best_overlap then
      best, best_overlap = { name }, score
    elseif score == best_overlap and score > 0 then
      best[#best + 1] = name
    end
  end

  if best_overlap == 0 then return nil end
  return nearest_by_distance(reponame, head, best)
end

-- Where HEAD sits relative to the trunk and the live bookmarks:
--   trunk_containing  the trunk HEAD is at or behind, including a jj HEAD
--                     detached mid-trunk
--   trunk_behind      jj only, since jj bookmarks don't advance with new
--                     work: the trunk strictly behind HEAD, when the commits
--                     past it are unclaimed trunk work that origin/<trunk>
--                     lacks. If origin contains HEAD, e.g. a local trunk
--                     rewound behind it, this is a historical review instead.
--                     In plain git, a detached HEAD past the trunk is a
--                     deliberate checkout, e.g. of a merged PR.
--   claim             jj only: the bookmark claiming HEAD's stack
--   ahead             detached jj only: the claim, else the trunk containing
--                     HEAD, if its tip is strictly ahead of HEAD. A bookmark
--                     diverged mid-rewrite is not.
local function locate_head(reponame, head, detached, refs)
  local loc = { head = head, refs = refs, jj = jj.is_repo(reponame) }

  for _, trunk in ipairs(TRUNKS) do
    local tip = refs.heads[trunk]
    local fork = tip and merge_base(reponame, tip, head)
    if fork == head then
      loc.trunk_containing = loc.trunk_containing or trunk
    elseif fork == tip and loc.jj and not loc.trunk_behind then
      local origin_tip = refs.remotes['origin/' .. trunk]
      if origin_tip and merge_base(reponame, origin_tip, head) ~= head then loc.trunk_behind = trunk end
    end
  end

  -- Claims only matter for a detached jj HEAD, or to void trunk work
  if loc.jj and (detached or loc.trunk_behind) then
    loc.claim = claim_head(reponame, head, refs)
    -- Trunk work only when no feature branch claims the stack
    if loc.claim then loc.trunk_behind = nil end
  end

  if loc.jj and detached then
    local candidate = loc.claim or loc.trunk_containing
    local tip = candidate and refs.heads[candidate]
    -- The containing trunk is at or ahead of HEAD by definition
    if tip and tip ~= head and (candidate ~= loc.claim or merge_base(reponame, tip, head) == head) then
      loc.ahead = candidate
    end
  end

  return loc
end

-- Locating HEAD runs a log per local branch but depends only on the refs, so
-- it is cached by HEAD and a fingerprint of every branch tip. The git-dir
-- watcher can't invalidate it, since the watcher doesn't see writes under
-- refs/ and doesn't run in linked worktrees. Its VGitSync still clears the
-- cache, which bounds its size.
local locations = {}
event.custom_on('VGitSync', function(args)
  if args and args.data then locations = {} end
end)

-- Returns the location and HEAD's symbolic name, or nil, err.
local function locate_head_cached(reponame)
  local head, branch = read_head(reponame)
  if not head then return nil, branch end
  local refs, err = read_refs(reponame)
  if not refs then return nil, err end

  local detached = branch == 'HEAD'
  local fingerprint = utils.str.fnv1a(table.concat(refs.output, '\n'))
  local key = string.format('%s|%s|%s|%s', reponame, head, tostring(detached), fingerprint)
  locations[key] = locations[key] or locate_head(reponame, head, detached, refs)
  return locations[key], branch
end

-- The default review base, first that exists:
--   1. origin/<trunk> when HEAD is on the trunk (at or behind its tip, or
--      past a lagging jj bookmark), to review unpushed trunk work
--   2. local main, then master. These beat origin so that a PR can be
--      reviewed after it merged: point local master at the PR's pre-merge
--      base (`git branch -f master <sha>`) and reopen
--   3. origin/HEAD's target
--   4. origin/main, then origin/master
local function detect_base(loc)
  local refs = loc.refs
  local trunk = loc.trunk_containing or loc.trunk_behind
  if trunk and refs.remotes['origin/' .. trunk] then return 'origin/' .. trunk end

  for _, name in ipairs(TRUNKS) do
    if refs.heads[name] then return name end
  end
  if refs.origin_head then return refs.origin_head end
  for _, name in ipairs(TRUNKS) do
    if refs.remotes['origin/' .. name] then return 'origin/' .. name end
  end

  return nil, { 'Could not detect base branch. Please specify it as an argument.' }
end

-- The persistence key for HEAD's review: its branch, which is stable across
-- rebases. A rebase in progress keys by the branch being rebased. In plain
-- git, a deliberately detached HEAD keys as "HEAD". In jj, however, git HEAD
-- is always detached at the working copy's parent, so the branch is recovered
-- instead of keying every branch's work under "HEAD".
--
-- With stacked branches, a substack's reviewed subjects all sit inside the
-- superstack, so content overlap alone would key the superstack to the
-- substack's review. Only topology can tell "this stack, rebased" from "a
-- superstack built on it", so live bookmarks outrank the stored-review
-- resolver (`resolve_detached`). Stored reviews are the fallback for deleted
-- or unreachable bookmarks, then trunk work keys as the trunk.
local function branch_key(reponame, loc, branch, base, resolve_detached)
  local rebase_branch = read_rebase_head_name(reponame)
  if rebase_branch then return rebase_branch end
  if branch ~= 'HEAD' or not loc.jj then return branch end

  return loc.claim
    or (resolve_detached and resolve_detached(base, loc.head))
    or loc.trunk_containing
    or loc.trunk_behind
    or branch
end

-- The ref (and hash) the review diffs run to. Normally HEAD, but in a jj
-- repo the working copy is routinely parked mid-stack, and reviewing to HEAD
-- would silently truncate the review to the commits below the parking spot,
-- so it runs to the tip ahead of HEAD (`loc.ahead`) instead.
local function review_head(loc)
  if not loc.ahead then return 'HEAD', loc.head end
  return loc.ahead, loc.refs.heads[loc.ahead]
end

-- Resolve what to review: the base (`base_arg`, else detected), the branch
-- key the review persists under, the head it runs to, and their merge base.
-- `head_ref` is for display, and every git call uses `head_hash`, so a ref
-- moving mid-fetch can't mix commits. A trunk review (base = origin/<branch
-- key>) also counts its unpushed commits. `resolve_detached(base, head_hash)`
-- is the stored-review fallback for a detached jj HEAD that no bookmark
-- claims, returning a branch key or nil.
function git_branch.review_target(reponame, base_arg, resolve_detached)
  local loc, branch = locate_head_cached(reponame)
  if not loc then return nil, branch end

  local base = base_arg ~= '' and base_arg or nil
  if not base then
    local base_err
    base, base_err = detect_base(loc)
    if not base then return nil, base_err end
  end

  local key = branch_key(reponame, loc, branch, base, resolve_detached)
  local head_ref, head_hash = review_head(loc)
  local fork, fork_err = merge_base(reponame, base, head_hash)
  if not fork then return nil, fork_err end

  local is_trunk_review = base == 'origin/' .. key
  local unpushed_count
  if is_trunk_review then
    local count = gitcli.run({ '-C', reponame, 'rev-list', '--count', fork .. '..' .. head_hash })
    unpushed_count = count and tonumber(count[1])
    if unpushed_count == 0 then unpushed_count = nil end
  end

  return {
    base = base,
    branch_key = key,
    head_ref = head_ref,
    head_hash = head_hash,
    merge_base = fork,
    is_trunk_review = is_trunk_review,
    unpushed_count = unpushed_count,
  }
end

local FETCH_INTERVAL_SECS = 3600

-- Per `<reponame>|<ref>`: { last_success = os.time(), in_progress = bool }
local fetch_state = {}

-- The environment for a background fetch, which must never prompt: git's
-- terminal prompt and every askpass helper are off (an empty GIT_ASKPASS
-- makes git skip core.askPass and SSH_ASKPASS too), and ssh runs in batch
-- mode unless the user configured their own ssh command.
local function no_prompt_env(reponame)
  local env = vim.loop.os_environ()
  env.GIT_TERMINAL_PROMPT = '0'
  env.GIT_ASKPASS = ''
  env.SSH_ASKPASS = ''
  env.SSH_ASKPASS_REQUIRE = 'never'
  if not env.GIT_SSH_COMMAND and not env.GIT_SSH then
    local configured = gitcli.run({ '-C', reponame, 'config', '--get', 'core.sshCommand' })
    if not configured or #configured == 0 then env.GIT_SSH_COMMAND = 'ssh -o BatchMode=yes' end
  end

  local list = {}
  for name, value in pairs(env) do
    list[#list + 1] = name .. '=' .. value
  end
  return list
end

-- Fetch a remote-tracking ref in the background if it wasn't fetched in the
-- last FETCH_INTERVAL_SECS. Notifies only if the ref moved.
function git_branch.fetch_ref_if_stale(reponame, ref)
  if not reponame or not ref then return end

  local remote, branch = ref:match('^([^/]+)/(.+)$')
  if not remote then return end

  local key = reponame .. '|' .. ref
  local state = fetch_state[key] or {}
  fetch_state[key] = state
  if state.in_progress then return end
  if state.last_success and os.time() - state.last_success < FETCH_INTERVAL_SECS then return end

  state.in_progress = true
  loop.coroutine(function()
    local old_tip = rev_parse(reponame, ref)
    local _, err = gitcli.run(
      { '-C', reponame, 'fetch', remote, branch },
      { by_exit_code = true, env = no_prompt_env(reponame) }
    )
    state.in_progress = false
    if err then return end

    state.last_success = os.time()
    if rev_parse(reponame, ref) ~= old_tip then
      console.info(string.format('Fetched %s — reopen to see updated diff', ref))
    end
  end)()
end

-- Commits in `base_ref..head_ref`, oldest first
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
  }, { by_exit_code = true })
  if err then return nil, err end

  -- An undescribed jj commit has an empty subject; keep it
  local commits = {}
  for _, line in ipairs(result) do
    if line ~= '' then
      local hash, short_hash, message = line:match('^(%x+)|(%x+)|(.*)$')
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

-- The by-commit review's commits in `merge_base..head`, oldest first, from one
-- git log: { hash, short_hash, message, body, files }. `message` is the
-- subject (%s), which joins a multi-line first paragraph and which record keys
-- hash. `body` is the full message as lines, and `files` the name-status list.
function git_branch.review_commits(reponame, merge_base, head)
  -- Per commit: '\1<hash>', short hash, subject, body, then name-status records
  local output, err = gitcli.run({
    '-C',
    reponame,
    '--no-pager',
    'log',
    '--reverse',
    '--name-status',
    '-z',
    '--format=%x01%H%x00%h%x00%s%x00%B',
    merge_base .. '..' .. head,
  }, { by_exit_code = true, raw = true })
  if err then return nil, err end

  local commits = {}
  local tokens = split_nul(output)
  local i = 1
  while tokens[i] do
    local hash = tokens[i]:match('^\1(%x+)$')
    if hash then
      local body = vim.split(tokens[i + 3], '\n', { plain = true })
      while #body > 0 and body[#body] == '' do
        body[#body] = nil
      end

      local commit = { hash = hash, short_hash = tokens[i + 1], message = tokens[i + 2], body = body, files = {} }
      commits[#commits + 1] = commit
      i = parse_name_status(tokens, i + 4, commit.files)
    else
      i = i + 1
    end
  end

  return commits
end

-- Files changed on `head_ref` since its merge base with `base_ref`
function git_branch.changed_files(reponame, base_ref, head_ref)
  if not reponame then return nil, { 'reponame is required' } end
  if not base_ref then return nil, { 'base_ref is required' } end

  head_ref = head_ref or 'HEAD'

  local output, err = gitcli.run({
    '-C',
    reponame,
    '--no-pager',
    'diff',
    '--name-status',
    '-z',
    base_ref .. '...' .. head_ref,
  }, { by_exit_code = true, raw = true })
  if err then return nil, err end

  local files = {}
  parse_name_status(split_nul(output), 1, files)
  return files
end

return git_branch
