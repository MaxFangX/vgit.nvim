-- Not a module path: plenary runs specs without the repo root on package.path
local review = dofile('tests/helpers/review.lua')
local ReviewState = require('vgit.features.screens.ReviewState')
local change_id_rekey = require('vgit.features.screens.change_id_rekey')
local persistence = require('vgit.features.screens.ReviewPersistence')

local eq = assert.are.same
local run = review.run

local function new_state(opts)
  return ReviewState(vim.tbl_extend('force', { review_type = 'by_commit' }, opts))
end

local function item(key, filepath, change_id)
  return { key = key, filepath = filepath, change_id = change_id }
end

describe('change_id_rekey', function()
  review.use_temp_data_home()

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

  describe('ReviewState:reconcile_change_ids', function()
    local cid = 'tvnuvoxmqpwrkxlsyrmzxuyokmnplwtx'

    it('rekeys an approved record after the subject is reworded', function()
      local state = new_state({ branch_name = 'rekey', base_branch = 'origin/master' })
      state:set_approved('oldsubj:src/a.lua', { 'approved' }, false, { 'base' })
      state:reconcile_change_ids({ item('oldsubj:src/a.lua', 'src/a.lua', cid) })

      state:reconcile_change_ids({ item('newsubj:src/a.lua', 'src/a.lua', cid) })
      eq(state:get_approved('newsubj:src/a.lua').lines, { 'approved' })
      eq(state:get_approved('oldsubj:src/a.lua'), nil)
    end)

    it('keeps a record found by subject when the change id was re-derived (git rebase)', function()
      local state = new_state({ branch_name = 'rebase', base_branch = 'origin/master' })
      state:set_approved('subj:src/a.lua', { 'approved' }, false, { 'base' })
      state:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })

      state:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', 'rederived') })
      eq(state:get_approved('subj:src/a.lua').lines, { 'approved' })
    end)

    -- Session 1 records `before` ({ key, change id } per item, each item
    -- approved as its change id), session 2 sees `after`
    local function rekeyed(before, after)
      local state = review.fresh_review_state()({ review_type = 'by_commit', branch_name = 'shift' })
      local items = {}
      for i, key in ipairs(before) do
        items[i] = item(key[1], 'f', key[2])
        state:set_approved(key[1], { key[2] }, false, { 'base' })
      end
      state:reconcile_change_ids(items)

      items = {}
      for i, key in ipairs(after) do
        items[i] = item(key[1], 'f', key[2])
      end
      state:reconcile_change_ids(items)
      return function(key)
        local record = state:get_approved(key)
        return record and record.lines[1]
      end
    end

    it('follows subjects renumbered by an inserted commit', function()
      local approved = rekeyed({ { 'step2:f', 'X' }, { 'step3:f', 'Y' } }, { { 'step3:f', 'X' }, { 'step4:f', 'Y' } })
      eq(approved('step3:f'), 'X')
      eq(approved('step4:f'), 'Y')
      eq(approved('step2:f'), nil)
    end)

    it('follows swapped subjects', function()
      local approved = rekeyed({ { 'A:f', 'X' }, { 'B:f', 'Y' } }, { { 'B:f', 'X' }, { 'A:f', 'Y' } })
      eq(approved('B:f'), 'X')
      eq(approved('A:f'), 'Y')
    end)

    it("does not move a divergent commit's record to its twin", function()
      local approved = rekeyed({ { 'A:f', 'X' } }, { { 'A:f', 'X' }, { 'B:f', 'X' } })
      eq(approved('A:f'), 'X')
      eq(approved('B:f'), nil)
    end)

    it('rekeys a record approved in an earlier session', function()
      run(function()
        local opts = { review_type = 'by_commit', branch_name = 'reload', repo_name = 'repo' }
        local before = new_state(opts)
        before:set_approved('oldsubj:src/a.lua', { 'approved' }, false, { 'base' })
        before:reconcile_change_ids({ item('oldsubj:src/a.lua', 'src/a.lua', cid) })
        before:save()

        local after = review.fresh_review_state()(opts)
        after:load_from_disk()
        after:reconcile_change_ids({ item('newsubj:src/a.lua', 'src/a.lua', cid) })
        eq(after:get_approved('newsubj:src/a.lua').lines, { 'approved' })
        eq(after:get_approved('oldsubj:src/a.lua'), nil)
      end)
    end)
  end)

  describe('adopting from other branches by change id:', function()
    local cid = 'xlspqkuoplmnrtwzxyvkosmrwlzyqtvn'

    it("adopts an approved record from another branch's review of the same commit", function()
      run(function()
        local sibling = new_state({ branch_name = 'pool-sibling', repo_name = 'repo' })
        sibling:set_approved('subj:src/a.lua', { 'approved' }, false, { 'base' })
        sibling:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
        sibling:save()

        local current = new_state({ branch_name = 'pool-current', repo_name = 'repo' })
        current:reconcile_change_ids({
          item('subj:src/a.lua', 'src/a.lua', cid),
          item('subj:src/b.lua', 'src/b.lua', 'unrelated'),
        })
        eq(current:get_approved('subj:src/a.lua').lines, { 'approved' })
        eq(current:get_approved('subj:src/a.lua').base_lines, { 'base' })
        eq(current:get_approved('subj:src/b.lua'), nil)

        -- The adopted record is now this branch's own, objects included
        current:save()
        local data = persistence.load('repo', 'pool-current', 'by_commit')
        local entry = data.entries['subj:src/a.lua']
        eq(entry.change_id, cid)
        eq(persistence.read_object('repo', 'pool-current', entry.approved), { 'approved' })
      end)
    end)

    -- `lower` holds a record for (cid, a.lua); `upper` adopts it on open
    local function adopted_by_upper()
      local ReviewState = review.fresh_review_state()
      local lower = ReviewState({ review_type = 'by_commit', branch_name = 'lower', repo_name = 'repo' })
      lower:set_approved('subj:src/a.lua', { 'approved' }, false, { 'base' })
      lower:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
      lower:save()

      local upper = ReviewState({ review_type = 'by_commit', branch_name = 'upper', repo_name = 'repo' })
      upper:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
      eq(upper:get_approved('subj:src/a.lua').lines, { 'approved' })
      return upper
    end

    local function reopen_upper()
      local upper = review.fresh_review_state()({ review_type = 'by_commit', branch_name = 'upper', repo_name = 'repo' })
      upper:load_from_disk()
      upper:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
      return upper
    end

    it('does not adopt a record again after it was unmarked', function()
      run(function()
        local upper = adopted_by_upper()
        upper:remove_approved('subj:src/a.lua')
        upper:save()

        eq(reopen_upper():get_approved('subj:src/a.lua'), nil)
      end)
    end)

    it('does not adopt records again after a reset', function()
      run(function()
        local upper = adopted_by_upper()
        upper:reset()
        upper:save()

        eq(reopen_upper():get_approved('subj:src/a.lua'), nil)
      end)
    end)

    it("keeps its own record over another branch's for the same commit", function()
      run(function()
        local sibling = new_state({ branch_name = 'own-sibling', repo_name = 'repo' })
        sibling:set_approved('subj:src/a.lua', { 'theirs' }, false, { 'base' })
        sibling:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
        sibling:save()

        local current = new_state({ branch_name = 'own-current', repo_name = 'repo' })
        current:set_approved('subj:src/a.lua', { 'mine' }, false, { 'base' })
        current:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
        eq(current:get_approved('subj:src/a.lua').lines, { 'mine' })
      end)
    end)
  end)
end)
