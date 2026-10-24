local async = require('plenary.async.tests')
local loop = require('vgit.core.loop')
local git_branch = require('vgit.git.git_branch')

local eq = assert.are.same

-- Run shell `cmd` inside `dir`, aborting the test on non-zero exit. Git calls
-- resume in a fast event context, where vim.fn is forbidden, so hop out first.
local function sh(dir, cmd)
  if vim.in_fast_event() then loop.free_textlock() end
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

async.describe('review listings:', function()
  async.it('succeed despite warnings on stderr', function()
    -- More rename candidates than diff.renameLimit: git succeeds but warns
    local dir = make_repo()
    sh(dir, 'git config diff.renameLimit 1')
    sh(dir, 'printf "1\\n" > o1.txt && printf "2\\n" > o2.txt && git add -A && git commit -q -m old')
    sh(dir, 'git rm -q o1.txt o2.txt && printf "3\\n" > n1.txt && printf "4\\n" > n2.txt')
    sh(dir, 'git add -A && git commit -q -m new')

    local files, err = git_branch.changed_files(dir, 'HEAD~1', 'HEAD')
    eq(err, nil)
    eq(#files, 4)
    local by_commit = git_branch.all_commit_files(dir, 'HEAD~1', 'HEAD')
    eq(#vim.tbl_values(by_commit)[1], 4)
    cleanup(dir)
  end)
end)

async.describe('file listings:', function()
  local git_show = require('vgit.git.git_show')

  -- HEAD~1: base files; HEAD: one commit adding awkward paths, a rename with
  -- spaces, and a copy of a modified file (C under diff.renames=copies)
  local function make_paths_repo()
    local dir = make_repo()
    sh(dir, 'git config diff.renames copies')
    sh(dir, [[printf "x\n" > "old name.txt" && seq 1 50 > src.txt && git add -A && git commit -q -m base]])
    sh(dir, [[printf "u\n" > "café.txt" && printf "q\n" > 'q"uote.txt' && printf "t\n" > "$(printf 'ta\tb.txt')"]])
    sh(dir, [[git mv "old name.txt" "new name.txt" && cp src.txt dst.txt && echo 51 >> src.txt]])
    sh(dir, 'git add -A && git commit -q -m paths')
    return dir
  end

  local expected = {
    { status = 'A', filepath = 'café.txt' },
    { status = 'C', filepath = 'dst.txt', old_filepath = 'src.txt' },
    { status = 'R', filepath = 'new name.txt', old_filepath = 'old name.txt' },
    { status = 'A', filepath = 'q"uote.txt' },
    { status = 'M', filepath = 'src.txt' },
    { status = 'A', filepath = 'ta\tb.txt' },
  }

  local function sorted(files)
    table.sort(files, function(a, b)
      return a.filepath < b.filepath
    end)
    return files
  end

  async.it('parse quoted, non-ASCII, tab, renamed and copied paths', function()
    local dir = make_paths_repo()

    eq(sorted(git_branch.changed_files(dir, 'HEAD~1', 'HEAD')), expected)
    local by_commit = git_branch.all_commit_files(dir, 'HEAD~1', 'HEAD')
    eq(sorted(vim.tbl_values(by_commit)[1]), expected)

    -- Every parsed path names a real object
    local specs = {}
    for _, file in ipairs(expected) do
      specs[#specs + 1] = 'HEAD:' .. file.filepath
    end
    for _, result in ipairs(git_show.lines_batch(dir, specs)) do
      eq(result.missing, nil)
    end
    cleanup(dir)
  end)

  async.it('keep empty commits in the per-commit map', function()
    local dir = make_paths_repo()
    sh(dir, 'git commit -q --allow-empty -m empty')
    sh(dir, 'printf "b\\n" >> f.txt && git commit -q -am after')

    local by_commit = git_branch.all_commit_files(dir, 'HEAD~3', 'HEAD')
    loop.free_textlock()
    local function files_of(rev)
      return by_commit[vim.trim(vim.fn.system({ 'git', '-C', dir, 'rev-parse', rev }))]
    end
    eq(#files_of('HEAD~2'), #expected)
    eq(files_of('HEAD~1'), {})
    eq(files_of('HEAD'), { { status = 'M', filepath = 'f.txt' } })
    cleanup(dir)
  end)
end)

async.describe('commits_in_range:', function()
  async.it('keeps commits with empty or pipe-laden subjects', function()
    local dir = make_repo()
    sh(dir, 'git commit -q --allow-empty --allow-empty-message -m ""')
    sh(dir, 'git commit -q --allow-empty -m "a | b"')

    local commits = git_branch.commits_in_range(dir, 'HEAD~2', 'HEAD')
    eq(vim.tbl_map(function(commit)
      return commit.message
    end, commits), { '', 'a | b' })
    cleanup(dir)
  end)
end)

async.describe('resolution caches:', function()
  async.it('see a ref move that leaves HEAD in place', function()
    -- jj trunk work, then `jj bookmark create my-pr -r @-`: only a ref moves,
    -- which the git-dir watcher misses (and in a workspace never runs for)
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'git commit -q --allow-empty -m W1 && git commit -q --allow-empty -m W2')
    eq(git_branch.current_persistent(dir), 'master')
    eq(git_branch.detect_base(dir), 'origin/master')

    sh(dir, 'git branch my-pr HEAD')
    eq(git_branch.current_persistent(dir), 'my-pr')
    eq(git_branch.detect_base(dir), 'master')
    cleanup(dir)
  end)
end)

async.describe('resolution caches:', function()
  async.it('see a ref move that leaves HEAD in place', function()
    -- jj trunk work, then `jj bookmark create my-pr -r @-`: only a ref moves,
    -- which the git-dir watcher misses (and in a workspace never runs for)
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'git commit -q --allow-empty -m W1 && git commit -q --allow-empty -m W2')
    eq(git_branch.current_persistent(dir), 'master')
    eq(git_branch.detect_base(dir), 'origin/master')

    sh(dir, 'git branch my-pr HEAD')
    eq(git_branch.current_persistent(dir), 'my-pr')
    eq(git_branch.detect_base(dir), 'master')
    cleanup(dir)
  end)
end)

async.describe('trunk work:', function()
  async.it('keeps its trunk key when origin moves ahead', function()
    -- Unpushed jj trunk work, then a fetch brings in someone else's push
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'git commit -q --allow-empty -m other && git update-ref refs/remotes/origin/master HEAD')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'git commit -q --allow-empty -m U1 && git commit -q --allow-empty -m U2')

    eq(git_branch.current_persistent(dir), 'master')
    eq(git_branch.detect_base(dir), 'origin/master')
    cleanup(dir)
  end)
end)

async.describe('branch_for_head threshold:', function()
  async.it('ignores a stale bookmark sharing one generic subject', function()
    local dir = make_repo()
    sh(dir, 'git checkout -q -b old-pr && git commit -q --allow-empty -m "Old work"')
    sh(dir, 'git commit -q --allow-empty -m fmt')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'git commit -q --allow-empty -m "New feature A" && git commit -q --allow-empty -m fmt')

    eq(git_branch.branch_for_head(dir), nil)
    cleanup(dir)
  end)

  async.it('keeps a single-commit stack claimed by its rewritten bookmark', function()
    local dir = make_repo()
    sh(dir, 'git checkout -q -b feature && git commit -q --allow-empty -m F1')
    sh(dir, 'git checkout -q --detach master && git commit -q --allow-empty -m F1 -m rewritten')

    eq(git_branch.branch_for_head(dir), 'feature')
    cleanup(dir)
  end)
end)

async.describe('fetch_ref_if_stale:', function()
  -- An `ssh` that records what it was run with, then fails like a denied login
  local function fake_ssh(dir)
    sh(dir, 'mkdir bin')
    local script = dir .. '/bin/ssh'
    vim.fn.writefile({
      '#!/bin/sh',
      string.format(
        'echo "args=$* prompt=$GIT_TERMINAL_PROMPT askpass=[$GIT_ASKPASS] require=$SSH_ASKPASS_REQUIRE" > %s/ssh.log',
        dir
      ),
      'exit 255',
    }, script)
    vim.fn.setfperm(script, 'rwxr-xr-x')
    return script
  end

  local function fetch_log(dir)
    git_branch.fetch_ref_if_stale(dir, 'origin/master')
    loop.free_textlock()
    vim.wait(5000, function()
      return vim.loop.fs_stat(dir .. '/ssh.log') ~= nil
    end)
    return vim.fn.readfile(dir .. '/ssh.log')[1]
  end

  async.it('never prompts, and runs ssh in batch mode', function()
    local dir = make_repo()
    local script = fake_ssh(dir)
    sh(dir, 'git remote add origin ssh://vgit.invalid/repo.git')
    local path = vim.env.PATH
    vim.env.GIT_SSH_COMMAND, vim.env.GIT_SSH = nil, nil
    vim.env.PATH = vim.fs.dirname(script) .. ':' .. path

    local log = fetch_log(dir)
    vim.env.PATH = path
    assert.is_truthy(log:find('-o BatchMode=yes', 1, true))
    assert.is_truthy(log:find('prompt=0 askpass=[] require=never', 1, true))
    cleanup(dir)
  end)

  async.it("keeps the user's own ssh command", function()
    local dir = make_repo()
    sh(dir, 'git remote add origin ssh://vgit.invalid/repo.git')
    sh(dir, 'git config core.sshCommand ' .. fake_ssh(dir))
    vim.env.GIT_SSH_COMMAND, vim.env.GIT_SSH = nil, nil

    local log = fetch_log(dir)
    eq(log:find('BatchMode', 1, true), nil)
    assert.is_truthy(log:find('prompt=0', 1, true))
    cleanup(dir)
  end)
end)
