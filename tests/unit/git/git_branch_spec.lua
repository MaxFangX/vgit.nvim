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

-- Git calls leave us in a fast event context, where vim.fn.delete is
-- forbidden, so hop back to the main loop before cleanup.
local function cleanup(dir)
  loop.free_textlock()
  vim.fn.delete(dir, 'rf')
end

-- The review target for `dir`, failing the test on error
local function target(dir, base_arg, resolve_detached)
  local result, err = git_branch.review_target(dir, base_arg, resolve_detached)
  assert(result, vim.inspect(err))
  return result
end

local function key(dir, resolve_detached)
  return target(dir, nil, resolve_detached).branch_key
end

local function base(dir)
  return target(dir).base
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

async.describe('branch key, claimed by a live bookmark (jj):', function()
  async.it('prefers the feature branch over a backup/* snapshot at the same commit', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git checkout -q -b feature')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')
    sh(dir, 'git branch backup/feature feature') -- backup sits at the same commit
    sh(dir, 'git checkout -q --detach feature')  -- detached HEAD at the tip

    -- backup/feature ties feature at distance 0, so without the guard it would
    -- win the alphabetical tie-break and take the persistence key.
    eq(key(dir), 'feature')
    cleanup(dir)
  end)

  async.it('finds the feature branch when HEAD has moved ahead of its bookmark', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git checkout -q -b feature')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')
    -- Leave the `feature` bookmark at B and advance a detached HEAD past it, as jj
    -- does (git HEAD = working-copy parent, which outruns the bookmark).
    sh(dir, 'git checkout -q --detach feature')
    sh(dir, 'printf "c\\n" >> f.txt && git add f.txt && git commit -q -m C')

    -- feature is the only non-trunk candidate, so it resolves even with HEAD ahead of it.
    eq(key(dir), 'feature')
    cleanup(dir)
  end)

  async.it('resolves a diverged sibling by shared subjects (mid-stack amend)', function()
    -- As after a jj amend, before the bookmark re-exports, HEAD is a rewrite
    -- of the branch's stack, with different hashes but the same subjects,
    -- while an unrelated branch sits fewer commits away.
    local dir = make_repo() -- master @ A
    sh(dir, 'mkdir .jj')
    sh(dir, 'git checkout -q -b feature && printf "1\\n">>f.txt && git add f.txt && git commit -q -m F1')
    sh(dir, 'printf "2\\n">>f.txt && git add f.txt && git commit -q -m F2') -- feature: A->F1->F2
    sh(dir, 'git checkout -q -b near master && printf "n\\n">>f.txt && git add f.txt && git commit -q -m N') -- near: A->N
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "1x\\n">>f.txt && git add f.txt && git commit -q -m F1') -- HEAD: rewritten
    sh(dir, 'printf "2x\\n">>f.txt && git add f.txt && git commit -q -m F2') -- F1'->F2'

    -- near is closer by raw distance but shares no subjects; feature shares both.
    eq(key(dir), 'feature')
    cleanup(dir)
  end)

  async.it('ignores a merged bookmark parked on the trunk', function()
    -- A merged branch's bookmark left sitting on master inherits the trunk's
    -- proximity, but must not take the key from the real (diverged) branch.
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'printf "m\\n">>f.txt && git add f.txt && git commit -q -m M') -- master: A->M
    sh(dir, 'git branch merged-thing master') -- parked on the trunk tip
    sh(dir, 'git checkout -q -b feature && printf "1\\n">>f.txt && git add f.txt && git commit -q -m F1')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "1x\\n">>f.txt && git add f.txt && git commit -q -m F1') -- rewrite of F1
    sh(dir, 'printf "2\\n">>f.txt && git add f.txt && git commit -q -m F2')

    -- merged-thing has no commits past the trunk (zero overlap by construction)
    eq(key(dir), 'feature')
    cleanup(dir)
  end)

  async.it('is not claimed when no branch shares HEAD stack subjects', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git checkout -q -b stale && printf "s\\n">>f.txt && git add f.txt && git commit -q -m S')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "d\\n">>f.txt && git add f.txt && git commit -q -m D')

    -- stale is the only candidate but shares no subjects with HEAD's stack,
    -- so claiming it would key the review to an unrelated branch.
    eq(key(dir), 'HEAD')
    cleanup(dir)
  end)

  async.it('ignores trunk and backups as claimants', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git branch backup/master master')
    sh(dir, 'git checkout -q --detach master')

    -- Both candidates are excluded, leaving the trunk containing HEAD
    eq(key(dir), 'master')
    cleanup(dir)
  end)
end)

async.describe('base:', function()
  async.it('redirects to origin/master when master has unpushed commits', function()
    local dir = make_repo()
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')

    eq(base(dir), 'origin/master')
    cleanup(dir)
  end)

  async.it('redirects to origin/main for a main-based repo', function()
    local dir = make_repo()
    sh(dir, 'git branch -m master main')
    sh(dir, 'git update-ref refs/remotes/origin/main main')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')

    eq(base(dir), 'origin/main')
    cleanup(dir)
  end)

  async.it('redirects for a detached HEAD behind the trunk (jj shape)', function()
    local dir = make_repo()
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')
    sh(dir, 'git checkout -q --detach master^') -- jj working-copy parent mid-stack

    eq(base(dir), 'origin/master')
    cleanup(dir)
  end)

  async.it('keeps local master as base on a feature branch', function()
    local dir = make_repo()
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q -b feature')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')

    eq(base(dir), 'master')
    cleanup(dir)
  end)

  async.it('redirects when HEAD is ahead of a lagging trunk bookmark (jj trunk work)', function()
    -- In jj, committing on the trunk advances HEAD (the working-copy parent)
    -- but not the master bookmark, so HEAD is still on master.
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')

    eq(base(dir), 'origin/master')
    cleanup(dir)
  end)

  async.it('keeps local master for a descendant HEAD claimed by a feature branch', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')
    sh(dir, 'git branch feature') -- bookmark at HEAD: feature work, not trunk work

    eq(base(dir), 'master')
    cleanup(dir)
  end)

  async.it('keeps a local master rewound behind origin (merged-PR review in jj)', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')
    sh(dir, 'git update-ref refs/remotes/origin/master master') -- origin at B (post-merge)
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'git branch -f master master^') -- rewind master to A (the PR's pre-merge base)

    eq(base(dir), 'master')
    cleanup(dir)
  end)

  async.it('keeps local master when HEAD descends from it (merged-PR review)', function()
    -- Reviewing a merged PR: master repointed at the pre-merge base, HEAD at
    -- the PR tip. HEAD is a descendant, not on the trunk, so no redirect.
    local dir = make_repo()
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')

    eq(base(dir), 'master')
    cleanup(dir)
  end)

  async.it('stays on local master when origin/master does not exist', function()
    local dir = make_repo()
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')

    eq(base(dir), 'master')
    cleanup(dir)
  end)
end)

async.describe('branch key:', function()
  async.it('keys detached trunk work as the trunk in a jj repo', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj') -- jj.is_repo only checks for this directory
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')
    sh(dir, 'git branch feature') -- the topology fallback would key on this
    sh(dir, 'git checkout -q --detach master')

    eq(key(dir), 'master')
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

    eq(key(dir), 'master')
    cleanup(dir)
  end)

  async.it('keys trunk work as trunk despite stale unrelated branches', function()
    -- The stale branch shares no subjects, so it doesn't claim HEAD ahead of
    -- the trunk fallback
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q -b stale && printf "s\\n">>f.txt && git add f.txt && git commit -q -m S')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "b\\n">>f.txt && git add f.txt && git commit -q -m B')

    eq(key(dir), 'master')
    cleanup(dir)
  end)

  async.it('prefers a feature branch over the lagging-trunk fallback', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'printf "b\\n" >> f.txt && git add f.txt && git commit -q -m B')
    sh(dir, 'git branch feature')

    eq(key(dir), 'feature')
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

    eq(key(dir, function() return 'sub' end), 'super')
    cleanup(dir)
  end)

  async.it('prefers a content-resolved review branch over the trunk key', function()
    -- e.g. a feature reviewed pre-merge then fast-forwarded into master: the
    -- stored review (matched by commit subjects) keeps its key.
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git checkout -q --detach master')

    eq(key(dir, function() return 'feature' end), 'feature')
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
    eq(#git_branch.review_commits(dir, 'HEAD~1', 'HEAD')[1].files, 4)
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
    eq(sorted(git_branch.review_commits(dir, 'HEAD~1', 'HEAD')[1].files), expected)

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

  async.it('keep empty commits in the per-commit lists', function()
    local dir = make_paths_repo()
    sh(dir, 'git commit -q --allow-empty -m empty')
    sh(dir, 'printf "b\\n" >> f.txt && git commit -q -am after')

    local commits = git_branch.review_commits(dir, 'HEAD~3', 'HEAD')
    eq(#commits[1].files, #expected)
    eq(commits[2].files, {})
    eq(commits[3].files, { { status = 'M', filepath = 'f.txt' } })
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
    eq(key(dir), 'master')
    eq(base(dir), 'origin/master')

    sh(dir, 'git branch my-pr HEAD')
    eq(key(dir), 'my-pr')
    eq(base(dir), 'master')
    cleanup(dir)
  end)
end)

describe('git_branch.subjects_qualify:', function()
  it('takes two shared subjects, or a small stack sharing all of its own', function()
    eq(git_branch.subjects_qualify(2, 5, 9), true)
    eq(git_branch.subjects_qualify(1, 1, 2), true)
    -- One stray subject can't claim a larger stack
    eq(git_branch.subjects_qualify(1, 1, 3), false)
    eq(git_branch.subjects_qualify(1, 2, 1), false)
    eq(git_branch.subjects_qualify(0, 0, 1), false)
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

    eq(key(dir), 'master')
    eq(base(dir), 'origin/master')
    cleanup(dir)
  end)
end)

async.describe('branch key claim threshold (jj):', function()
  async.it('ignores a stale bookmark sharing one generic subject', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git checkout -q -b old-pr && git commit -q --allow-empty -m "Old work"')
    sh(dir, 'git commit -q --allow-empty -m fmt')
    sh(dir, 'git checkout -q --detach master')
    sh(dir, 'git commit -q --allow-empty -m "New feature A" && git commit -q --allow-empty -m fmt')

    eq(key(dir), 'HEAD')
    cleanup(dir)
  end)

  async.it('keeps a single-commit stack claimed by its rewritten bookmark', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git checkout -q -b feature && git commit -q --allow-empty -m F1')
    sh(dir, 'git checkout -q --detach master && git commit -q --allow-empty -m F1 -m rewritten')

    eq(key(dir), 'feature')
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

async.describe('review head:', function()
  local function rev(dir, ref)
    loop.free_textlock()
    return vim.trim(vim.fn.system({ 'git', '-C', dir, 'rev-parse', ref }))
  end

  async.it('runs to the claiming bookmark when HEAD is parked mid-stack (jj)', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git checkout -q -b feature && git commit -q --allow-empty -m F1 && git commit -q --allow-empty -m F2')
    sh(dir, 'git checkout -q --detach feature~1')

    local t = target(dir)
    eq({ t.branch_key, t.head_ref, t.head_hash }, { 'feature', 'feature', rev(dir, 'feature') })
    eq(t.merge_base, rev(dir, 'master'))
    cleanup(dir)
  end)

  async.it('stays at HEAD for a diverged bookmark (jj)', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj')
    sh(dir, 'git checkout -q -b feature && git commit -q --allow-empty -m F1 && git commit -q --allow-empty -m F2')
    -- Mid-stack amend: F1 rewritten, F2 rebased onto it
    sh(dir, 'git checkout -q --detach master && printf "x\\n" >> f.txt && git commit -q -am F1')
    sh(dir, 'git commit -q --allow-empty -m F2')

    local t = target(dir)
    eq({ t.branch_key, t.head_ref, t.head_hash }, { 'feature', 'HEAD', rev(dir, 'HEAD') })
    cleanup(dir)
  end)

  async.it('runs to the trunk tip when HEAD is behind it (jj)', function()
    local dir = make_repo()
    sh(dir, 'git update-ref refs/remotes/origin/master master')
    sh(dir, 'mkdir .jj && git commit -q --allow-empty -m B && git checkout -q --detach master~1')

    local t = target(dir)
    eq({ t.branch_key, t.base, t.head_ref }, { 'master', 'origin/master', 'master' })
    eq({ t.is_trunk_review, t.unpushed_count }, { true, 1 })
    cleanup(dir)
  end)

  async.it('stays at HEAD outside jj', function()
    local dir = make_repo()
    sh(dir, 'git checkout -q -b feature && git commit -q --allow-empty -m F1 && git commit -q --allow-empty -m F2')
    sh(dir, 'git checkout -q --detach feature~1')

    local t = target(dir)
    eq({ t.branch_key, t.head_ref, t.is_trunk_review, t.unpushed_count }, { 'HEAD', 'HEAD', false, nil })
    cleanup(dir)
  end)
end)

async.describe('stored-review fallback:', function()
  async.it('is asked with the base and head only when no bookmark claims HEAD', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jj && git checkout -q --detach && git commit -q --allow-empty -m D')
    local asked
    eq(key(dir, function(...)
      asked = { ... }
      return 'stored'
    end), 'stored')
    eq(asked[1], 'master')
    eq(#asked[2], 40)

    sh(dir, 'git branch feature HEAD')
    asked = nil
    eq(key(dir, function(...)
      asked = { ... }
    end), 'feature')
    eq(asked, nil)
    cleanup(dir)
  end)

  async.it('uses the given base', function()
    local dir = make_repo()
    sh(dir, 'git checkout -q -b feature && git commit -q --allow-empty -m F1')
    eq(target(dir, 'HEAD~1').base, 'HEAD~1')
    eq(target(dir, '').base, 'master')
    cleanup(dir)
  end)
end)

async.describe('review_commits:', function()
  async.it('lists commits with subjects, bodies and files from one log', function()
    local dir = make_repo()
    sh(dir, 'git commit -q --allow-empty --allow-empty-message -m ""')
    sh(dir, [[printf "b\n" >> f.txt && printf "x\n" > "sp ace.txt" && git add -A]])
    sh(dir, [[git commit -q -m "Two line" -m "first paragraph" -m "Body line" -m "" ]])
    sh(dir, 'git mv f.txt g.txt && git commit -q -m "Move"')

    local commits = git_branch.review_commits(dir, 'HEAD~3', 'HEAD')
    eq(#commits, 3)
    eq({ commits[1].message, commits[1].body, commits[1].files }, { '', {}, {} })
    eq(commits[2].message, 'Two line')
    eq(commits[2].body, { 'Two line', '', 'first paragraph', '', 'Body line' })
    eq(commits[2].files, { { status = 'M', filepath = 'f.txt' }, { status = 'A', filepath = 'sp ace.txt' } })
    eq(commits[3].files, { { status = 'R', filepath = 'g.txt', old_filepath = 'f.txt' } })

    -- Same commits, subjects and order as commits_in_range
    local listed = git_branch.commits_in_range(dir, 'HEAD~3', 'HEAD')
    for n, commit in ipairs(listed) do
      local got = commits[n]
      eq({ got.hash, got.short_hash, got.message }, { commit.hash, commit.short_hash, commit.message })
    end
    cleanup(dir)
  end)

  async.it('keeps a multi-line first paragraph joined in the subject', function()
    local dir = make_repo()
    sh(dir, [[git commit -q --allow-empty -F - <<'MSG'
Subject that
wraps

Body
MSG]])
    local commits = git_branch.review_commits(dir, 'HEAD~1', 'HEAD')
    eq(commits[1].message, 'Subject that wraps')
    eq(commits[1].body, { 'Subject that', 'wraps', '', 'Body' })
    cleanup(dir)
  end)
end)

async.describe('jj conflict artifacts:', function()
  async.it('are dropped from every file listing', function()
    local dir = make_repo()
    sh(dir, 'mkdir .jjconflict-base-0 && printf "c\\n" > .jjconflict-base-0/f.txt')
    sh(dir, 'printf "r\\n" > JJ-CONFLICT-README')
    sh(dir, 'printf "b\\n" >> f.txt && git add -A && git commit -q -m conflicted')

    local only_f = { { status = 'M', filepath = 'f.txt' } }
    eq(git_branch.changed_files(dir, 'HEAD~1', 'HEAD'), only_f)
    eq(git_branch.review_commits(dir, 'HEAD~1', 'HEAD')[1].files, only_f)
    cleanup(dir)
  end)
end)
