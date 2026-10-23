local loop = require('vgit.core.loop')
local ReviewState = require('vgit.features.screens.ReviewState')
local IndexedReviewState = require('vgit.features.screens.IndexedReviewState')
local change_id_rekey = require('vgit.features.screens.change_id_rekey')
local indexed_persistence = require('vgit.features.screens.IndexedReviewPersistence')
local classic_persistence = require('vgit.features.screens.ReviewStatePersistence')

local eq = assert.are.same

-- Run `fn` in a vgit coroutine (save/load yield through free_textlock) and
-- block until it finishes.
local function run(fn)
  local done = false
  loop.coroutine(function()
    fn()
    done = true
  end)()
  assert(vim.wait(5000, function() return done end, 10), 'coroutine did not finish')
end

describe('change_id_rekey.plan:', function()
  local cid = 'kzlnmouooqvwmnwmymlvpmmsuopnlkkt'

  it('moves an orphaned key to the item sharing its change id and file', function()
    local moves = change_id_rekey.plan(
      { { key = 'new:src/a.lua', filepath = 'src/a.lua', change_id = cid } },
      { ['old:src/a.lua'] = true },
      { ['old:src/a.lua'] = cid }
    )
    eq(moves, { { from = 'old:src/a.lua', to = 'new:src/a.lua' } })
  end)

  it('leaves a key that already holds state alone', function()
    local moves = change_id_rekey.plan(
      { { key = 'new:src/a.lua', filepath = 'src/a.lua', change_id = cid } },
      { ['new:src/a.lua'] = true, ['old:src/a.lua'] = true },
      { ['old:src/a.lua'] = cid }
    )
    eq(moves, {})
  end)

  it('does not match a different change id or a different file', function()
    local held = { ['old:src/a.lua'] = true, ['old:src/b.lua'] = true }
    local ids = { ['old:src/a.lua'] = cid, ['old:src/b.lua'] = cid }
    eq(change_id_rekey.plan({ { key = 'new:src/a.lua', filepath = 'src/a.lua', change_id = 'other' } }, held, ids), {})
    eq(change_id_rekey.plan({ { key = 'new:src/c.lua', filepath = 'src/c.lua', change_id = cid } }, held, ids), {})
  end)
end)

describe('IndexedReviewState:reconcile_change_ids', function()
  local cid = 'tvnuvoxmqpwrkxlsyrmzxuyokmnplwtx'

  local function state_for(branch)
    return IndexedReviewState({ review_type = 'by_commit_indexed', branch_name = branch, base_branch = 'origin/master' })
  end

  it('rekeys an approved record after the subject is reworded', function()
    local state = state_for('rekey-indexed')
    state:set_approved('oldsubj:src/a.lua', { 'approved' }, false, { 'base' })
    state:reconcile_change_ids({ { key = 'oldsubj:src/a.lua', filepath = 'src/a.lua', change_id = cid } })

    state:reconcile_change_ids({ { key = 'newsubj:src/a.lua', filepath = 'src/a.lua', change_id = cid } })
    eq(state:get_approved('newsubj:src/a.lua').lines, { 'approved' })
    eq(state:get_approved('oldsubj:src/a.lua'), nil)
  end)

  it('keeps a record found by subject when the change id was re-derived (git rebase)', function()
    local state = state_for('rebase-indexed')
    state:set_approved('subj:src/a.lua', { 'approved' }, false, { 'base' })
    state:reconcile_change_ids({ { key = 'subj:src/a.lua', filepath = 'src/a.lua', change_id = cid } })

    state:reconcile_change_ids({ { key = 'subj:src/a.lua', filepath = 'src/a.lua', change_id = 'rederived' } })
    eq(state:get_approved('subj:src/a.lua').lines, { 'approved' })
  end)

  it('persists change ids alongside approved records', function()
    local saved_xdg, root = vim.env.XDG_DATA_HOME, vim.fn.tempname()
    vim.env.XDG_DATA_HOME = root

    run(function()
      local state = IndexedReviewState({
        review_type = 'by_commit_indexed', branch_name = 'persist-indexed', repo_name = 'repo',
      })
      state:set_approved('subj:src/a.lua', { 'approved' }, false, { 'base' })
      state:reconcile_change_ids({ { key = 'subj:src/a.lua', filepath = 'src/a.lua', change_id = cid } })
      state:save()

      local data = indexed_persistence.load('repo', 'persist-indexed', 'by_commit_indexed')
      eq(data.entries['subj:src/a.lua'].change_id, cid)
    end)

    vim.env.XDG_DATA_HOME = saved_xdg
    vim.fn.delete(root, 'rf')
  end)
end)

describe('ReviewState:reconcile_change_ids', function()
  local cid = 'npktmlpzvwyrsxqkuoplmnrtwzxyvkos'

  it('moves every mark under a reworded subject to the new key', function()
    local state = ReviewState({ review_type = 'by_commit', branch_name = 'rekey-classic', base_branch = 'origin/master' })
    state:mark_hunk('oldsubj:src/a.lua', 'c1')
    state:mark_hunk('oldsubj:src/a.lua', 'c2')
    state:mark_hunk('oldsubj:src/b.lua', 'c3')
    state:reconcile_change_ids({
      { key = 'oldsubj:src/a.lua', filepath = 'src/a.lua', change_id = cid },
      { key = 'oldsubj:src/b.lua', filepath = 'src/b.lua', change_id = cid },
    })

    state:reconcile_change_ids({
      { key = 'newsubj:src/a.lua', filepath = 'src/a.lua', change_id = cid },
      { key = 'newsubj:src/b.lua', filepath = 'src/b.lua', change_id = cid },
    })
    eq(state:is_hunk_seen('newsubj:src/a.lua', 'c1'), true)
    eq(state:is_hunk_seen('newsubj:src/a.lua', 'c2'), true)
    eq(state:is_hunk_seen('newsubj:src/b.lua', 'c3'), true)
    eq(state:is_hunk_seen('oldsubj:src/a.lua', 'c1'), false)
  end)

  it('persists change ids only for keys holding marks', function()
    local saved_xdg, root = vim.env.XDG_DATA_HOME, vim.fn.tempname()
    vim.env.XDG_DATA_HOME = root

    run(function()
      local state = ReviewState({ review_type = 'by_commit', branch_name = 'persist-classic', repo_name = 'repo' })
      state:mark_hunk('subj:src/a.lua', 'c1')
      state:reconcile_change_ids({
        { key = 'subj:src/a.lua', filepath = 'src/a.lua', change_id = cid },
        { key = 'subj:src/unmarked.lua', filepath = 'src/unmarked.lua', change_id = cid },
      })
      state:save()

      local data = classic_persistence.load('repo', 'persist-classic', 'by_commit')
      eq(data.changeIds, { ['subj:src/a.lua'] = cid })
    end)

    vim.env.XDG_DATA_HOME = saved_xdg
    vim.fn.delete(root, 'rf')
  end)
end)
