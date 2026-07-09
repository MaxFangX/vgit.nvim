local GitStatus = require('vgit.git.GitStatus')

local eq = assert.are.same

describe('GitStatus:', function()
  describe('classification', function()
    it('treats an intent-to-add file (` A`) as an unstaged addition', function()
      -- `git add -N` reports the porcelain code ` A`, which must be surfaced like
      -- untracked `??`.
      local status = GitStatus(' A new_file.txt')

      eq(status.value, ' A')
      eq(status:is_unstaged(), true)
      eq(status:is_staged(), false)
      eq(status:is_unmerged(), false)
    end)

    it('classifies untracked, staged, and unstaged files correctly', function()
      eq(GitStatus('?? untracked.txt'):is_unstaged(), true)
      eq(GitStatus('A  added.txt'):is_staged(), true)
      eq(GitStatus(' M modified.txt'):is_unstaged(), true)
      eq(GitStatus('M  staged.txt'):is_staged(), true)
      eq(GitStatus('UU conflict.txt'):is_unmerged(), true)
    end)
  end)
end)
