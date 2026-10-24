local loop = require('vgit.core.loop')
local Spawn = require('vgit.core.Spawn')

local jj = {}

--[[
  jj (Jujutsu) awareness.

  In a repo colocated with git, jj keeps git HEAD detached at the working
  copy's parent, so logic that assumes an attached branch (e.g. persistence
  keys) must adapt. Branch resolution stays git-native, since jj bookmarks can
  diverge from git branches. The jj binary is only consulted for change ids,
  which are shown in place of hashes and follow a commit's records across
  rewording, and vgit works without it.
]]

-- Whether `reponame` has a `.jj` store at its root. Safe in fast event contexts.
function jj.is_repo(reponame)
  if not reponame then return false end
  local stat = vim.loop.fs_stat(reponame .. '/.jj')
  return stat ~= nil and stat.type == 'directory'
end

-- jj stores an unresolved conflict in the git tree as sidecar paths
-- (.jjconflict-base-N/…, .jjconflict-side-N/…) plus a JJ-CONFLICT-README.
-- jj reserves these names, so the check is safe outside jj repos too.
function jj.is_conflict_artifact(filepath)
  if not filepath then return false end
  return filepath:match('^%.jjconflict%-') ~= nil or filepath == 'JJ-CONFLICT-README'
end

-- Run a jj subcommand under `reponame`, returning its stdout, or nil if jj is
-- missing or exits nonzero. Without `--ignore-working-copy`, jj would snapshot
-- the working copy and reset it to git HEAD, but a viewer must never move the
-- user's checkout.
local run_jj = loop.suspend(function(reponame, args, callback)
  local argv = { '-R', reponame, '--ignore-working-copy', '--color', 'never' }
  for _, arg in ipairs(args) do
    argv[#argv + 1] = arg
  end

  local output
  Spawn({
    command = 'jj',
    args = argv,
    on_stdout_raw = function(raw)
      output = raw
    end,
    on_exit = function(code)
      vim.schedule(function()
        callback(code == 0 and output or nil)
      end)
    end,
  }):start()
end, 3)

-- Map full git commit hashes to `{ id, short }` jj change ids in one `jj log`
-- call, where `short` is the shortest unique prefix. `present()` skips commits
-- jj hasn't imported instead of erroring, so they are missing from the map.
-- Returns nil if jj is missing or fails.
local function fetch_change_ids(reponame, commit_hashes)
  local revset = {}
  for i, hash in ipairs(commit_hashes) do
    revset[i] = string.format('present(%s)', hash)
  end

  local output = run_jj(reponame, {
    'log',
    '--no-graph',
    '-r', table.concat(revset, '|'),
    '-T', 'commit_id ++ " " ++ change_id ++ " " ++ change_id.shortest() ++ "\n"',
  })
  if not output then return nil end

  local ids = {}
  for hash, id, short in output:gmatch('(%x+) (%S+) (%S+)') do
    ids[hash] = { id = id, short = short }
  end
  return ids
end

-- Attach jj change ids to each commit (`{ hash = ... }` tables) in a jj repo.
-- `change_id` is the full id, which identifies a commit across rewording.
-- `change_id_short` is the shortest unique prefix, for display. Outside jj
-- repos, or when jj is unavailable, this is a no-op. Must be called from a
-- coroutine.
function jj.attach_change_ids(reponame, commits)
  if not jj.is_repo(reponame) then return end

  local hashes = {}
  for i, commit in ipairs(commits) do
    hashes[i] = commit.hash
  end

  local change_ids = fetch_change_ids(reponame, hashes)
  if not change_ids then return end

  for _, commit in ipairs(commits) do
    local ids = change_ids[commit.hash]
    if ids then
      commit.change_id = ids.id
      commit.change_id_short = ids.short
    end
  end
end

return jj
