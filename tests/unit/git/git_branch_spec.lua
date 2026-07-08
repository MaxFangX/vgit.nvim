local async = require('plenary.async.tests')
local loop = require('vgit.core.loop')
local git_branch = require('vgit.git.git_branch')

local eq = assert.are.same

-- Run shell `cmd` inside `dir`, aborting the test on non-zero exit.
local function sh(dir, cmd)
  vim.fn.system(string.format('cd %s && %s', vim.fn.shellescape(dir), cmd))
  assert(vim.v.shell_error == 0, 'command failed: ' .. cmd)
end

-- `branch_for_head` leaves us in a fast event context (async git via vim.schedule),
-- where vim.fn.delete is forbidden — hop back to the main loop before cleanup.
local function cleanup(dir)
  loop.free_textlock()
  vim.fn.delete(dir, 'rf')
end

-- Fresh repo with a single `master` commit. Caller adds topology.
local function make_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  sh(dir, 'git init -q -b master')
  sh(dir, 'git config user.email t@t.co && git config user.name t')
  sh(dir, 'printf "a\\n" > f.txt && git add f.txt && git commit -q -m A')
  return dir
end

async.describe('branch_for_head:', function()
  async.it('prefers the feature branch over a backup/* snapshot at the same commit', function()
    local dir = make_repo()
    sh(dir, 'git checkout -q -b feature')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')
    sh(dir, 'git branch backup/feature feature') -- backup sits at the same commit
    sh(dir, 'git checkout -q --detach feature')  -- detached HEAD at the tip

    -- backup/feature ties feature at distance 0; without the guard it would win
    -- the alphabetical tie-break and hijack the persistence key.
    eq(git_branch.branch_for_head(dir), 'feature')
    cleanup(dir)
  end)

  async.it('finds the feature branch when HEAD has moved ahead of its bookmark', function()
    local dir = make_repo()
    sh(dir, 'git checkout -q -b feature')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')
    -- Leave the `feature` bookmark at B and advance a detached HEAD past it, as jj
    -- does (git HEAD = working-copy parent, which outruns the bookmark).
    sh(dir, 'git checkout -q --detach feature')
    sh(dir, 'printf "c\\n" >> f.txt && git add f.txt && git commit -q -m C')

    -- feature is the only non-trunk candidate, so it resolves even with HEAD ahead of it.
    eq(git_branch.branch_for_head(dir), 'feature')
    cleanup(dir)
  end)

  async.it('resolves a diverged sibling by shared subjects (mid-stack amend)', function()
    -- Mimics a jj amend before the bookmark re-exports: HEAD is a rewrite of
    -- the branch's stack — different hashes, same subjects — while an
    -- unrelated branch sits fewer commits away.
    local dir = make_repo() -- master @ A
    sh(dir, 'git checkout -q -b feature && printf "1\\n">>f.txt && git add f.txt && git commit -q -m F1')
    sh(dir, 'printf "2\\n">>f.txt && git add f.txt && git commit -q -m F2') -- feature: A->F1->F2
    sh(dir, 'git checkout -q -b near master && printf "n\\n">>f.txt && git add f.txt && git commit -q -m N') -- near: A->N
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "1x\\n">>f.txt && git add f.txt && git commit -q -m F1') -- HEAD: rewritten
    sh(dir, 'printf "2x\\n">>f.txt && git add f.txt && git commit -q -m F2') -- F1'->F2'

    -- near is closer by raw distance but shares no subjects; feature shares both.
    eq(git_branch.branch_for_head(dir), 'feature')
    cleanup(dir)
  end)

  async.it('ignores a merged bookmark parked on the trunk', function()
    -- A merged branch's bookmark left sitting on master inherits the trunk's
    -- proximity; it must not hijack the key from the real (diverged) branch.
    local dir = make_repo()
    sh(dir, 'printf "m\\n">>f.txt && git add f.txt && git commit -q -m M') -- master: A->M
    sh(dir, 'git branch merged-thing master') -- parked on the trunk tip
    sh(dir, 'git checkout -q -b feature && printf "1\\n">>f.txt && git add f.txt && git commit -q -m F1')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "1x\\n">>f.txt && git add f.txt && git commit -q -m F1') -- rewrite of F1
    sh(dir, 'printf "2\\n">>f.txt && git add f.txt && git commit -q -m F2')

    -- merged-thing has no commits past the trunk (zero overlap by construction)
    eq(git_branch.branch_for_head(dir), 'feature')
    cleanup(dir)
  end)

  async.it('returns nil when no branch shares HEAD stack subjects', function()
    local dir = make_repo()
    sh(dir, 'git checkout -q -b stale && printf "s\\n">>f.txt && git add f.txt && git commit -q -m S')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "d\\n">>f.txt && git add f.txt && git commit -q -m D')

    -- stale is the only candidate but shares no subjects with HEAD's stack;
    -- claiming it would key the review to an unrelated branch.
    eq(git_branch.branch_for_head(dir), nil)
    cleanup(dir)
  end)

  async.it('ignores trunk, returning nil when only master/backup are candidates', function()
    local dir = make_repo()
    sh(dir, 'git branch backup/master master')
    sh(dir, 'git checkout -q --detach master')

    -- Both candidates are excluded, so there is no feature branch to key on.
    eq(git_branch.branch_for_head(dir), nil)
    cleanup(dir)
  end)
end)

async.describe('detect_base:', function()
  async.it('redirects to origin/master when master has unpushed commits', function()
    local dir = make_repo()
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')

    eq(git_branch.detect_base(dir), 'origin/master')
    cleanup(dir)
  end)

  async.it('redirects to origin/main for a main-based repo', function()
    local dir = make_repo()
    sh(dir, 'git branch -m master main')
    sh(dir, 'git update-ref refs/remotes/origin/main main')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')

    eq(git_branch.detect_base(dir), 'origin/main')
    cleanup(dir)
  end)

  async.it('redirects for a detached HEAD behind the trunk (jj shape)', function()
    local dir = make_repo()
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')
    sh(dir, 'git checkout -q --detach master^') -- jj working-copy parent mid-stack

    eq(git_branch.detect_base(dir), 'origin/master')
    cleanup(dir)
  end)

  async.it('keeps local master as base on a feature branch', function()
    local dir = make_repo()
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q -b feature')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')

    eq(git_branch.detect_base(dir), 'master')
    cleanup(dir)
  end)

  async.it('redirects when HEAD is ahead of a lagging trunk bookmark (jj trunk work)', function()
    -- jj: committing on the trunk advances HEAD (the working-copy parent) but
    -- not the master bookmark — conceptually still "on master".
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')

    eq(git_branch.detect_base(dir), 'origin/master')
    cleanup(dir)
  end)

  async.it('keeps local master for a descendant HEAD claimed by a feature branch', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')
    sh(dir, 'git branch feature') -- bookmark at HEAD: feature work, not trunk work

    eq(git_branch.detect_base(dir), 'master')
    cleanup(dir)
  end)

  async.it('keeps a local master rewound behind origin (merged-PR review in jj)', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')
    sh(dir, 'git update-ref refs/remotes/origin/master master') -- origin at B (post-merge)
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'git branch -f master master^') -- rewind master to A (the PR's pre-merge base)

    eq(git_branch.detect_base(dir), 'master')
    cleanup(dir)
  end)

  async.it('keeps local master when HEAD descends from it (merged-PR review)', function()
    -- Reviewing a merged PR: master repointed at the pre-merge base, HEAD at
    -- the PR tip. HEAD is a descendant, not on the trunk, so no redirect.
    local dir = make_repo()
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')

    eq(git_branch.detect_base(dir), 'master')
    cleanup(dir)
  end)

  async.it('stays on local master when origin/master does not exist', function()
    local dir = make_repo()
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')

    eq(git_branch.detect_base(dir), 'master')
    cleanup(dir)
  end)
end)

async.describe('current_persistent:', function()
  async.it('keys detached trunk work as the trunk in a jj repo', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj') -- jj.is_repo only checks for this directory
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')
    sh(dir, 'git branch feature') -- the topology fallback would key on this
    sh(dir, 'git checkout -q --detach master')

    eq(git_branch.current_persistent(dir), 'master')
    cleanup(dir)
  end)

  async.it('keys unpushed trunk work as the trunk in a jj repo', function()
    -- HEAD ahead of the master bookmark (jj doesn't auto-advance it), no
    -- feature branch anywhere: keyed "master", not the literal "HEAD".
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')

    eq(git_branch.current_persistent(dir), 'master')
    cleanup(dir)
  end)

  async.it('keys trunk work as trunk despite stale unrelated branches', function()
    -- A stale branch used to win the old distance ranking and claim the key;
    -- with zero subject overlap it no longer blocks the trunk fallback.
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q -b stale && printf "s\\n">>f.txt && git add f.txt && git commit -q -m S')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "b\\n">>f.txt && git add f.txt && git commit -q -m B')

    eq(git_branch.current_persistent(dir), 'master')
    cleanup(dir)
  end)

  async.it('prefers a feature branch over the lagging-trunk fallback', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')
    sh(dir, 'git branch feature')

    eq(git_branch.current_persistent(dir), 'feature')
    cleanup(dir)
  end)

  async.it('lets a bookmark claiming HEAD outrank the stored-review resolver', function()
    -- Stacked branches: the substack's reviewed subjects all sit inside the
    -- superstack, so content overlap alone would key the superstack to the
    -- substack's (possibly larger) review. The live bookmark at HEAD decides.
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git checkout -q -b sub && printf "1\\n">>f.txt && git add f.txt && git commit -q -m S1')
    sh(dir, 'git checkout -q -b super && printf "2\\n">>f.txt && git add f.txt && git commit -q -m X1')
    sh(dir, 'git checkout -q --detach super')

    eq(git_branch.current_persistent(dir, function() return 'sub' end), 'super')
    cleanup(dir)
  end)

  async.it('prefers a content-resolved review branch over the trunk key', function()
    -- e.g. a feature reviewed pre-merge then fast-forwarded into master: the
    -- stored review (matched by commit subjects) keeps its key.
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git checkout -q --detach master')

    eq(git_branch.current_persistent(dir, function() return 'feature' end), 'feature')
    cleanup(dir)
  end)
end)
