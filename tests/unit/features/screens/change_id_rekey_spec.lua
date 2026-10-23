local loop = require('vgit.core.loop')
local ReviewState = require('vgit.features.screens.ReviewState')
local IndexedReviewState = require('vgit.features.screens.IndexedReviewState')
local change_id_rekey = require('vgit.features.screens.change_id_rekey')
local indexed_persistence = require('vgit.features.screens.IndexedReviewPersistence')
local classic_persistence = require('vgit.features.screens.ReviewStatePersistence')

local eq = assert.are.same

-- Save and load yield through free_textlock, so run `fn` in a vgit coroutine
-- and block until it finishes.
local function run(fn)
  local done = false
  loop.coroutine(function()
    fn()
    done = true
  end)()
  assert(vim.wait(5000, function() return done end, 10), 'coroutine did not finish')
end

local function indexed_state(opts)
  return IndexedReviewState(vim.tbl_extend('force', { review_type = 'by_commit_indexed' }, opts))
end

local function classic_state(opts)
  return ReviewState(vim.tbl_extend('force', { review_type = 'by_commit' }, opts))
end

local function item(key, filepath, change_id)
  return { key = key, filepath = filepath, change_id = change_id }
end

describe('change_id_rekey', function()
  -- Every spec writes under a throwaway data home, restored even when an
  -- assertion fails.
  local saved_xdg, root
  before_each(function()
    saved_xdg = vim.env.XDG_DATA_HOME
    root = vim.fn.tempname()
    vim.env.XDG_DATA_HOME = root
  end)
  after_each(function()
    vim.env.XDG_DATA_HOME = saved_xdg
    vim.fn.delete(root, 'rf')
  end)

  describe('plan:', function()
    local cid = 'kzlnmouooqvwmnwmymlvpmmsuopnlkkt'

    it('moves an orphaned key to the item sharing its change id and file', function()
      local moves = change_id_rekey.plan(
        { item('new:src/a.lua', 'src/a.lua', cid) },
        { ['old:src/a.lua'] = true },
        { ['old:src/a.lua'] = cid }
      )
      eq(moves, { { from = 'old:src/a.lua', to = 'new:src/a.lua' } })
    end)

    it('leaves a key that already holds state alone', function()
      local moves = change_id_rekey.plan(
        { item('new:src/a.lua', 'src/a.lua', cid) },
        { ['new:src/a.lua'] = true, ['old:src/a.lua'] = true },
        { ['old:src/a.lua'] = cid }
      )
      eq(moves, {})
    end)

    it('does not match a different change id or a different file', function()
      local held = { ['old:src/a.lua'] = true, ['old:src/b.lua'] = true }
      local ids = { ['old:src/a.lua'] = cid, ['old:src/b.lua'] = cid }
      eq(change_id_rekey.plan({ item('new:src/a.lua', 'src/a.lua', 'other') }, held, ids), {})
      eq(change_id_rekey.plan({ item('new:src/c.lua', 'src/c.lua', cid) }, held, ids), {})
    end)
  end)

  describe('IndexedReviewState:reconcile_change_ids', function()
    local cid = 'tvnuvoxmqpwrkxlsyrmzxuyokmnplwtx'

    it('rekeys an approved record after the subject is reworded', function()
      local state = indexed_state({ branch_name = 'rekey-indexed', base_branch = 'origin/master' })
      state:set_approved('oldsubj:src/a.lua', { 'approved' }, false, { 'base' })
      state:reconcile_change_ids({ item('oldsubj:src/a.lua', 'src/a.lua', cid) })

      state:reconcile_change_ids({ item('newsubj:src/a.lua', 'src/a.lua', cid) })
      eq(state:get_approved('newsubj:src/a.lua').lines, { 'approved' })
      eq(state:get_approved('oldsubj:src/a.lua'), nil)
    end)

    it('keeps a record found by subject when the change id was re-derived (git rebase)', function()
      local state = indexed_state({ branch_name = 'rebase-indexed', base_branch = 'origin/master' })
      state:set_approved('subj:src/a.lua', { 'approved' }, false, { 'base' })
      state:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })

      state:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', 'rederived') })
      eq(state:get_approved('subj:src/a.lua').lines, { 'approved' })
    end)

    it('rekeys a record approved in an earlier session', function()
      run(function()
        local opts = { branch_name = 'reload-indexed', repo_name = 'repo' }
        local before = indexed_state(vim.tbl_extend('force', opts, { base_branch = 'a' }))
        before:set_approved('oldsubj:src/a.lua', { 'approved' }, false, { 'base' })
        before:reconcile_change_ids({ item('oldsubj:src/a.lua', 'src/a.lua', cid) })
        before:save()

        -- A different base_branch is a fresh session state reading the same file
        local after = indexed_state(vim.tbl_extend('force', opts, { base_branch = 'b' }))
        after:load_from_disk()
        after:reconcile_change_ids({ item('newsubj:src/a.lua', 'src/a.lua', cid) })
        eq(after:get_approved('newsubj:src/a.lua').lines, { 'approved' })
        eq(after:get_approved('oldsubj:src/a.lua'), nil)
      end)
    end)
  end)

  describe('ReviewState:reconcile_change_ids', function()
    local cid = 'npktmlpzvwyrsxqkuoplmnrtwzxyvkos'

    it('moves every mark under a reworded subject to the new key', function()
      local state = classic_state({ branch_name = 'rekey-classic', base_branch = 'origin/master' })
      state:mark_hunk('oldsubj:src/a.lua', 'c1')
      state:mark_hunk('oldsubj:src/a.lua', 'c2')
      state:mark_hunk('oldsubj:src/b.lua', 'c3')
      state:reconcile_change_ids({
        item('oldsubj:src/a.lua', 'src/a.lua', cid),
        item('oldsubj:src/b.lua', 'src/b.lua', cid),
      })

      state:reconcile_change_ids({
        item('newsubj:src/a.lua', 'src/a.lua', cid),
        item('newsubj:src/b.lua', 'src/b.lua', cid),
      })
      eq(state:is_hunk_seen('newsubj:src/a.lua', 'c1'), true)
      eq(state:is_hunk_seen('newsubj:src/a.lua', 'c2'), true)
      eq(state:is_hunk_seen('newsubj:src/b.lua', 'c3'), true)
      eq(state:is_hunk_seen('oldsubj:src/a.lua', 'c1'), false)
    end)

    it('rekeys marks made in an earlier session', function()
      run(function()
        local opts = { branch_name = 'reload-classic', repo_name = 'repo' }
        local before = classic_state(vim.tbl_extend('force', opts, { base_branch = 'a' }))
        before:mark_hunk('oldsubj:src/a.lua', 'c1')
        before:reconcile_change_ids({ item('oldsubj:src/a.lua', 'src/a.lua', cid) })
        before:save()

        local after = classic_state(vim.tbl_extend('force', opts, { base_branch = 'b' }))
        after:load_from_disk()
        after:reconcile_change_ids({ item('newsubj:src/a.lua', 'src/a.lua', cid) })
        eq(after:is_hunk_seen('newsubj:src/a.lua', 'c1'), true)
        eq(after:is_hunk_seen('oldsubj:src/a.lua', 'c1'), false)
      end)
    end)

    it('persists change ids only for keys holding marks', function()
      run(function()
        local state = classic_state({ branch_name = 'persist-classic', repo_name = 'repo' })
        state:mark_hunk('subj:src/a.lua', 'c1')
        state:reconcile_change_ids({
          item('subj:src/a.lua', 'src/a.lua', cid),
          item('subj:src/unmarked.lua', 'src/unmarked.lua', cid),
        })
        state:save()

        local data = classic_persistence.load('repo', 'persist-classic', 'by_commit')
        eq(data.changeIds, { ['subj:src/a.lua'] = cid })
      end)
    end)
  end)

  describe('adopting from other branches by change id:', function()
    local cid = 'xlspqkuoplmnrtwzxyvkosmrwlzyqtvn'

    it("adopts an approved record from another branch's review of the same commit", function()
      run(function()
        local sibling = indexed_state({ branch_name = 'pool-sibling', repo_name = 'repo' })
        sibling:set_approved('subj:src/a.lua', { 'approved' }, false, { 'base' })
        sibling:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
        sibling:save()

        local current = indexed_state({ branch_name = 'pool-current', repo_name = 'repo' })
        current:reconcile_change_ids({
          item('subj:src/a.lua', 'src/a.lua', cid),
          item('subj:src/b.lua', 'src/b.lua', 'unrelated'),
        })
        eq(current:get_approved('subj:src/a.lua').lines, { 'approved' })
        eq(current:get_approved('subj:src/a.lua').base_lines, { 'base' })
        eq(current:get_approved('subj:src/b.lua'), nil)

        -- The adopted record is now this branch's own, objects included
        current:save()
        local data = indexed_persistence.load('repo', 'pool-current', 'by_commit_indexed')
        local entry = data.entries['subj:src/a.lua']
        eq(entry.change_id, cid)
        eq(indexed_persistence.read_object('repo', 'pool-current', entry.approved), { 'approved' })
      end)
    end)

    it("keeps its own record over another branch's for the same commit", function()
      run(function()
        local sibling = indexed_state({ branch_name = 'own-sibling', repo_name = 'repo' })
        sibling:set_approved('subj:src/a.lua', { 'theirs' }, false, { 'base' })
        sibling:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
        sibling:save()

        local current = indexed_state({ branch_name = 'own-current', repo_name = 'repo' })
        current:set_approved('subj:src/a.lua', { 'mine' }, false, { 'base' })
        current:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
        eq(current:get_approved('subj:src/a.lua').lines, { 'mine' })
      end)
    end)

    it("adopts hunk marks from another branch's review of the same commit", function()
      run(function()
        local sibling = classic_state({ branch_name = 'pool-sibling-c', repo_name = 'repo' })
        sibling:mark_hunk('subj:src/a.lua', 'c1')
        sibling:mark_hunk('subj:src/a.lua', 'c2')
        sibling:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
        sibling:save()

        local current = classic_state({ branch_name = 'pool-current-c', repo_name = 'repo' })
        current:reconcile_change_ids({ item('reworded:src/a.lua', 'src/a.lua', cid) })
        eq(current:is_hunk_seen('reworded:src/a.lua', 'c1'), true)
        eq(current:is_hunk_seen('reworded:src/a.lua', 'c2'), true)
      end)
    end)
  end)
end)
