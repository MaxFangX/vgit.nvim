-- The review Models against throwaway git repos
-- Not a module path: plenary runs specs without the repo root on package.path
local review = dofile('tests/helpers/review.lua')
local async = require('plenary.async.tests')
local loop = require('vgit.core.loop')
local utils = require('vgit.core.utils')
local git_show = require('vgit.git.git_show')
local GitStatus = require('vgit.git.GitStatus')
local record_keys = require('vgit.features.screens.record_keys')
local persistence = require('vgit.features.screens.review_persistence')
local ByCommitModel = require('vgit.features.screens.ProjectReviewByCommitScreen.Model')

local eq = assert.are.same

-- Run shell `cmd` inside `dir`, aborting the test on non-zero exit. Git calls
-- resume in a fast event context, where vim.fn is forbidden, so hop out first.
local function sh(dir, cmd)
  if vim.in_fast_event() then loop.free_textlock() end
  vim.fn.system(string.format('cd %s && %s', vim.fn.shellescape(dir), cmd))
  assert(vim.v.shell_error == 0, 'command failed: ' .. cmd)
end

-- A repo on `feature`, branched off a one-commit master and then built by
-- the shell `commands`, under a temp data home. Returns its dir and a
-- cleanup to call at the end of the spec (it must run in the spec's
-- coroutine, to hop out of the fast event context git calls leave behind).
local function make_repo(commands)
  local dir, saved_cwd = vim.fn.tempname(), vim.loop.cwd()
  local _, restore_homes = review.enter_temp_homes()
  vim.fn.mkdir(dir, 'p')
  sh(dir, 'git init -q -b master && git config user.email t@t.co && git config user.name t')
  sh(dir, 'printf "a\\n" > a.txt && git add a.txt && git commit -q -m A && git checkout -q -b feature')
  for _, cmd in ipairs(commands) do
    sh(dir, cmd)
  end

  return dir, function()
    loop.free_textlock()
    vim.cmd.cd(saved_cwd)
    vim.fn.delete(dir, 'rf')
    restore_homes()
  end
end

-- Fetch the by-commit review of the repo at `dir` against master
local function fetch_by_commit(dir)
  loop.free_textlock()
  vim.cmd.cd(dir)
  local model = ByCommitModel({ layout_type = 'unified' })
  local entries, err = model:fetch('master')
  return model, entries, err
end

-- The model's entries of `entry_type` for `filepath`, oldest commit first
local function entries_for(model, entry_type, filepath)
  local found = {}
  for _, section in ipairs(model:get_entries()) do
    for _, group in ipairs(section.commits) do
      for _, entry in ipairs(group.files) do
        if entry.type == entry_type and entry.filepath == filepath then found[#found + 1] = entry end
      end
    end
  end
  return found
end

async.describe('by-commit review model:', function()
  async.it('keys commits sharing a subject apart, and resolves their review by the same keys', function()
    local dir, cleanup = make_repo({
      'printf "1\\n" >> a.txt && git commit -q -am wip',
      'printf "b\\n" > b.txt && git add b.txt && git commit -q -m x',
      'printf "2\\n" >> a.txt && git commit -q -am wip',
    })
    local model = fetch_by_commit(dir)
    eq(#entries_for(model, 'unseen', 'a.txt'), 2)
    model:mark_file(entries_for(model, 'unseen', 'a.txt')[1])
    model:mark_file(entries_for(model, 'unseen', 'a.txt')[1])
    model:get_review_state():save()

    -- Both records survive under keys of their own
    local keys = vim.tbl_keys(persistence.load(vim.fn.fnamemodify(dir, ':t'), 'feature', 'by_commit').records)
    local expected = {
      record_keys.join(utils.str.fnv1a('wip'), 'a.txt'),
      record_keys.join(utils.str.fnv1a('wip\0' .. 2), 'a.txt'),
    }
    table.sort(keys)
    table.sort(expected)
    eq(keys, expected)

    -- A detached jj HEAD no bookmark claims finds the review by its subjects,
    -- which only matches both records if the resolver keys repeats the same way
    sh(dir, 'mkdir .jj && git checkout -q --detach feature && git branch -q -D feature')
    model = fetch_by_commit(dir)
    eq(model.state.branch_key, 'feature')
    eq(#entries_for(model, 'seen', 'a.txt'), 2)
    cleanup()
  end)

  async.it('lists commits with their entries, and finds entries by id', function()
    local dir, cleanup = make_repo({
      'printf "1\\n" >> a.txt && git commit -q -am one -m "Body line."',
      'git mv a.txt b.txt && printf "c\\n" > c.txt && git add c.txt && git commit -q -m two',
    })
    local model = fetch_by_commit(dir)
    local sections = model:get_entries()
    eq(#sections, 1)
    eq({ sections[1].type, sections[1].title }, { 'unseen', 'Unseen' })
    eq(vim.tbl_map(function(group) return group.index end, sections[1].commits), { 1, 2 })

    local one, two = sections[1].commits[1], sections[1].commits[2]
    eq(model:get_commit_message(one.commit.hash), { 'one', '', 'Body line.' })
    local renamed = entries_for(model, 'unseen', 'b.txt')[1]
    eq({ renamed.old_filepath, renamed.commit_hash, renamed.status.first }, { 'a.txt', two.commit.hash, 'R' })
    assert(renamed.status:is(GitStatus))

    -- Marking moves the entry to Seen, under the id its sibling names
    local entry = one.files[1]
    eq(model:lookup(entry.id), entry)
    model:mark_file(entry)
    local seen = model:lookup(model:sibling_id(entry))
    eq({ seen.type, seen.filepath }, { 'seen', 'a.txt' })
    eq(model:lookup(entry.id), nil)
    eq(model:get_entries()[1].type, 'seen')
    cleanup()
  end)

  async.it('fails when contents fail to load, rather than treating files as absent', function()
    local dir, cleanup = make_repo({ 'printf "1\\n" >> a.txt && git commit -q -am one' })
    local lines_batch = git_show.lines_batch
    git_show.lines_batch = function() return nil, { 'cat-file failed' } end
    local _, entries, err = fetch_by_commit(dir)
    git_show.lines_batch = lines_batch

    eq({ entries, err }, { nil, { 'cat-file failed' } })
    cleanup()
  end)
end)
