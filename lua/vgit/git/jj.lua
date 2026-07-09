local jj = {}

--[[
  jj (Jujutsu) awareness.

  vgit is a git plugin, but jj is commonly used colocated with git. In a colocated
  repo jj keeps git's HEAD detached at the working copy's parent, so git-only logic
  that assumes an attached branch (e.g. persistence keys) misbehaves. These helpers
  let vgit detect a jj repo and adapt, without depending on the jj binary — the
  underlying resolution stays git-native (jj's bookmark namespace can diverge from
  git branches, so it isn't a reliable source for git-keyed state).
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

return jj
