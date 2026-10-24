-- The review Models against throwaway git repos
local async = require('plenary.async.tests')
local loop = require('vgit.core.loop')
local utils = require('vgit.core.utils')
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

-- The by-commit model of the repo at `dir`, fetched against master
local function fetch_by_commit(dir)
  loop.free_textlock()
  vim.cmd.cd(dir)
  local model = ByCommitModel({ layout_type = 'unified' })
  local _, err = model:fetch('master')
  assert(not err, vim.inspect(err))
  return model
end

-- The model's entries of `entry_type` for `filepath`, oldest commit first
local function entries_for(model, entry_type, filepath)
  local found = {}
  for _, section in ipairs(model:get_entries()) do
    for _, commit in ipairs(section.commits) do
      for _, entry in ipairs(commit.files) do
        if entry.type == entry_type and entry.filepath == filepath then found[#found + 1] = entry end
      end
    end
  end
  return found
end

async.describe('by-commit review of commits sharing a subject:', function()
  local saved_cwd, saved_xdg, dir

  before_each(function()
    saved_cwd, saved_xdg = vim.loop.cwd(), vim.env.XDG_DATA_HOME
    vim.env.XDG_DATA_HOME = vim.fn.tempname()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    sh(dir, 'git init -q -b master && git config user.email t@t.co && git config user.name t')
    sh(dir, 'printf "a\\n" > a.txt && git add a.txt && git commit -q -m A')
    sh(dir, 'git checkout -q -b feature')
    sh(dir, 'printf "1\\n" >> a.txt && git commit -q -am wip')
    sh(dir, 'printf "b\\n" > b.txt && git add b.txt && git commit -q -m x')
    sh(dir, 'printf "2\\n" >> a.txt && git commit -q -am wip')
  end)

  -- Called at the end of each spec: git calls leave it in a fast event
  -- context, so it must hop to the main loop, which only a coroutine can
  local function cleanup()
    loop.free_textlock()
    vim.cmd.cd(saved_cwd)
    vim.fn.delete(dir, 'rf')
    vim.fn.delete(vim.env.XDG_DATA_HOME, 'rf')
    vim.env.XDG_DATA_HOME = saved_xdg
  end

  async.it('keys each commit apart, and resolves the stored review by the same keys', function()
    local model = fetch_by_commit(dir)
    local wips = entries_for(model, 'unseen', 'a.txt')
    eq(#wips, 2)
    model:mark_file(wips[1])
    -- The first mark moved the first commit's entry to Seen
    model:mark_file(entries_for(model, 'unseen', 'a.txt')[1])
    model:get_review_state():save()

    -- Both records survive under keys of their own
    local keys = vim.tbl_keys(persistence.load(vim.fn.fnamemodify(dir, ':t'), 'feature', 'by_commit').records)
    table.sort(keys)
    local expected = {
      record_keys.join(utils.str.fnv1a('wip'), 'a.txt'),
      record_keys.join(utils.str.fnv1a('wip\0' .. 2), 'a.txt'),
    }
    table.sort(expected)
    eq(keys, expected)

    -- A detached jj HEAD no bookmark claims finds the review by its subjects,
    -- which only matches both records if the resolver keys repeats the same way
    sh(dir, 'mkdir .jj && git checkout -q --detach feature && git branch -q -D feature')
    model = fetch_by_commit(dir)
    eq(model.state.branch_name, 'feature')
    eq(#entries_for(model, 'seen', 'a.txt'), 2)
    cleanup()
  end)
end)
