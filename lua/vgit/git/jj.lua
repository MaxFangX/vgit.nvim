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

return jj
