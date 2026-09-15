local loop = require('vgit.core.loop')

local jj = {}

--[[
  jj (Jujutsu) awareness.

  vgit is a git plugin, but jj is commonly used colocated with git. In a colocated
  repo jj keeps git's HEAD detached at the working copy's parent, so git-only logic
  that assumes an attached branch (e.g. persistence keys) misbehaves. These helpers
  let vgit detect a jj repo and adapt. Resolution stays git-native (jj's bookmark
  namespace can diverge from git branches, so it isn't a reliable source for
  git-keyed state); the jj binary is only consulted for cosmetic extras
  (`attach_change_ids`), with graceful fallback when it's absent. No helper
  here ever moves the user's checkout.
]]

-- Whether `reponame` is managed by jj (has a `.jj` store at its root). Used to
-- gate jj-aware behavior so plain-git users are unaffected. Uses libuv, so it's
-- safe in fast event contexts.
function jj.is_repo(reponame)
  if not reponame then return false end
  local stat = vim.loop.fs_stat(reponame .. '/.jj')
  return stat ~= nil and stat.type == 'directory'
end

-- jj stores an unresolved conflict in the git tree as sidecar paths
-- (.jjconflict-base-N/…, .jjconflict-side-N/…) plus a JJ-CONFLICT-README. These
-- are jj bookkeeping, not reviewable changes — and they can number in the
-- thousands, dominating diff/review load time — so vgit filters them out. The
-- names are jj-reserved, so the check is safe to run unconditionally.
function jj.is_conflict_artifact(filepath)
  if not filepath then return false end
  return filepath:match('^%.jjconflict%-') ~= nil or filepath == 'JJ-CONFLICT-README'
end

-- Return a new list of `{ filepath = ... }` entries with conflict artifacts removed.
function jj.filter_conflict_artifacts(files)
  local out = {}
  for _, file in ipairs(files) do
    if not jj.is_conflict_artifact(file.filepath) then
      out[#out + 1] = file
    end
  end
  return out
end

-- Run a jj subcommand under `reponame`, returning its stdout, or nil if jj is
-- missing or exits nonzero. Every call passes `--ignore-working-copy`: jj
-- would otherwise snapshot the working copy and reset it to git HEAD, and a
-- viewer must never move the user's checkout.
local run_jj = loop.suspend(function(reponame, args, callback)
  local argv = { '-R', reponame, '--ignore-working-copy', '--color', 'never' }
  for _, arg in ipairs(args) do
    argv[#argv + 1] = arg
  end

  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  local chunks = {}

  local handle
  handle = vim.loop.spawn('jj', {
    args = argv,
    stdio = { nil, stdout, stderr },
  }, function(code)
    stdout:read_stop()
    stderr:read_stop()
    if not stdout:is_closing() then stdout:close() end
    if not stderr:is_closing() then stderr:close() end
    if handle and not handle:is_closing() then handle:close() end

    local output = code == 0 and table.concat(chunks) or nil
    vim.schedule(function()
      callback(output)
    end)
  end)

  -- Spawn failed (jj binary not installed)
  if not handle then
    stdout:close()
    stderr:close()
    return callback(nil)
  end

  stdout:read_start(function(_, chunk)
    if chunk then chunks[#chunks + 1] = chunk end
  end)
  stderr:read_start(function() end)
end, 3)

-- Map full git commit hashes -> jj change ids, as the shortest unique prefix
-- `jj log` shows, in one `jj log` call. `present()` drops commits jj hasn't
-- imported instead of erroring, so an unknown commit is just missing from
-- the map. Returns nil when jj is missing or fails; callers then keep git
-- hashes.
local function fetch_change_ids(reponame, commit_hashes)
  local revset = {}
  for i, hash in ipairs(commit_hashes) do
    revset[i] = string.format('present(%s)', hash)
  end

  local output = run_jj(reponame, {
    'log',
    '--no-graph',
    '-r', table.concat(revset, '|'),
    '-T', 'commit_id ++ " " ++ change_id.shortest() ++ "\n"',
  })
  if not output then return nil end

  local ids = {}
  for hash, change_id in output:gmatch('(%x+) (%S+)') do
    ids[hash] = change_id
  end
  return ids
end

-- Attach `change_id` to each commit (`{ hash = ... }` tables) for display in
-- a jj repo. Outside jj repos, or when jj is unavailable, this is a no-op
-- and git short hashes remain the display. Must be called from a coroutine
-- context.
function jj.attach_change_ids(reponame, commits)
  if not jj.is_repo(reponame) or #commits == 0 then return end

  local hashes = {}
  for i, commit in ipairs(commits) do
    hashes[i] = commit.hash
  end

  local change_ids = fetch_change_ids(reponame, hashes)
  if not change_ids then return end

  for _, commit in ipairs(commits) do
    commit.change_id = change_ids[commit.hash]
  end
end

return jj
