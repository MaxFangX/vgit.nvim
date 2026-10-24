-- Not a module path: plenary runs specs without the repo root on package.path
local review = dofile('tests/helpers/review.lua')
local ReviewState = require('vgit.features.screens.ReviewState')
local utils = require('vgit.core.utils')
local record_keys = require('vgit.features.screens.record_keys')
local persistence = require('vgit.features.screens.review_persistence')

local eq = assert.are.same
local run = review.run

local function new_state(opts)
  return ReviewState(vim.tbl_extend('force', { review_type = 'by_commit' }, opts))
end

local function item(key, filepath, change_id)
  return { key = key, filepath = filepath, change_id = change_id }
end

describe('record_keys', function()
  review.use_temp_data_home()

  describe('format:', function()
    it('keys a subject the way stored records are keyed', function()
      -- Frozen: every stored by-commit key depends on these
      eq(record_keys.subject_key('  Add a  '), '8df4a362')
      eq(record_keys.join('8df4a362', 'src/a:b.lua'), '8df4a362:src/a:b.lua')
      eq({ record_keys.split('8df4a362:src/a:b.lua') }, { '8df4a362', 'src/a:b.lua' })
    end)

    it('keys repeated subjects apart, keeping the first plain', function()
      local keys = record_keys.subject_keys({ 'wip', 'Add a', ' wip', '', 'wip', '' })
      eq(keys[1], record_keys.subject_key('wip'))
      eq(keys[2], record_keys.subject_key('Add a'))
      eq(keys[3], utils.str.fnv1a('wip\0' .. 2))
      eq(keys[4], record_keys.subject_key(''))
      eq(keys[5], utils.str.fnv1a('wip\0' .. 3))
      eq(keys[6], utils.str.fnv1a('\0' .. 2))
    end)
  end)

  describe('plan:', function()
    local cid = 'kzlnmouooqvwmnwmymlvpmmsuopnlkkt'

    it('moves an orphaned key to the item sharing its change id and file', function()
      local moves = record_keys.plan(
        { item('new:src/a.lua', 'src/a.lua', cid) },
        { ['old:src/a.lua'] = true },
        { ['old:src/a.lua'] = cid }
      )
      eq(moves, { { from = 'old:src/a.lua', to = 'new:src/a.lua' } })
    end)

    it('leaves a key that already holds state alone', function()
      local moves = record_keys.plan(
        { item('new:src/a.lua', 'src/a.lua', cid) },
        { ['new:src/a.lua'] = true, ['old:src/a.lua'] = true },
        { ['old:src/a.lua'] = cid }
      )
      eq(moves, {})
    end)

    it('does not match a different change id or a different file', function()
      local held = { ['old:src/a.lua'] = true, ['old:src/b.lua'] = true }
      local ids = { ['old:src/a.lua'] = cid, ['old:src/b.lua'] = cid }
      eq(record_keys.plan({ item('new:src/a.lua', 'src/a.lua', 'other') }, held, ids), {})
      eq(record_keys.plan({ item('new:src/c.lua', 'src/c.lua', cid) }, held, ids), {})
    end)
  end)

  describe('ReviewState:reconcile_change_ids', function()
    local cid = 'tvnuvoxmqpwrkxlsyrmzxuyokmnplwtx'

    it('rekeys an approved record after the subject is reworded', function()
      local state = new_state({ branch_key = 'rekey' })
      state:set_record('oldsubj:src/a.lua', { 'approved' }, false, { 'base' })
      state:reconcile_change_ids({ item('oldsubj:src/a.lua', 'src/a.lua', cid) })

      state:reconcile_change_ids({ item('newsubj:src/a.lua', 'src/a.lua', cid) })
      eq(state:get_record('newsubj:src/a.lua').lines, { 'approved' })
      eq(state:get_record('oldsubj:src/a.lua'), nil)
    end)

    it('keeps a record found by subject when the change id was re-derived (git rebase)', function()
      local state = new_state({ branch_key = 'rebase' })
      state:set_record('subj:src/a.lua', { 'approved' }, false, { 'base' })
      state:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })

      state:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', 'rederived') })
      eq(state:get_record('subj:src/a.lua').lines, { 'approved' })
    end)

    -- Session 1 records `before` ({ key, change id } per item, each item
    -- approved as its change id), session 2 sees `after`
    local function rekeyed(before, after)
      local state = review.fresh_review_state()({ review_type = 'by_commit', branch_key = 'shift' })
      local items = {}
      for i, key in ipairs(before) do
        items[i] = item(key[1], 'f', key[2])
        state:set_record(key[1], { key[2] }, false, { 'base' })
      end
      state:reconcile_change_ids(items)

      items = {}
      for i, key in ipairs(after) do
        items[i] = item(key[1], 'f', key[2])
      end
      state:reconcile_change_ids(items)
      return function(key)
        local record = state:get_record(key)
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
        local opts = { review_type = 'by_commit', branch_key = 'reload', repo_key = 'repo' }
        local before = new_state(opts)
        before:set_record('oldsubj:src/a.lua', { 'approved' }, false, { 'base' })
        before:reconcile_change_ids({ item('oldsubj:src/a.lua', 'src/a.lua', cid) })
        before:save()

        local after = review.fresh_review_state()(opts)
        after:load_from_disk()
        after:reconcile_change_ids({ item('newsubj:src/a.lua', 'src/a.lua', cid) })
        eq(after:get_record('newsubj:src/a.lua').lines, { 'approved' })
        eq(after:get_record('oldsubj:src/a.lua'), nil)
      end)
    end)
  end)

  describe('adopting from other branches by change id:', function()
    local cid = 'xlspqkuoplmnrtwzxyvkosmrwlzyqtvn'

    it("adopts an approved record from another branch's review of the same commit", function()
      run(function()
        local sibling = new_state({ branch_key = 'pool-sibling', repo_key = 'repo' })
        sibling:set_record('subj:src/a.lua', { 'approved' }, false, { 'base' })
        sibling:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
        sibling:save()

        local current = new_state({ branch_key = 'pool-current', repo_key = 'repo' })
        current:reconcile_change_ids({
          item('subj:src/a.lua', 'src/a.lua', cid),
          item('subj:src/b.lua', 'src/b.lua', 'unrelated'),
        })
        eq(current:get_record('subj:src/a.lua').lines, { 'approved' })
        eq(current:get_record('subj:src/a.lua').base_lines, { 'base' })
        eq(current:get_record('subj:src/b.lua'), nil)

        -- The adopted record is now this branch's own, objects included
        current:save()
        local ref = persistence.load('repo', 'pool-current', 'by_commit').records['subj:src/a.lua']
        eq(ref.change_id, cid)
        eq(persistence.read_object('repo', 'pool-current', ref.hash), { 'approved' })
      end)
    end)

    -- `lower` holds a record for (cid, a.lua); `upper` adopts it on open
    local function adopted_by_upper()
      local ReviewState = review.fresh_review_state()
      local lower = ReviewState({ review_type = 'by_commit', branch_key = 'lower', repo_key = 'repo' })
      lower:set_record('subj:src/a.lua', { 'approved' }, false, { 'base' })
      lower:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
      lower:save()

      local upper = ReviewState({ review_type = 'by_commit', branch_key = 'upper', repo_key = 'repo' })
      upper:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
      eq(upper:get_record('subj:src/a.lua').lines, { 'approved' })
      return upper
    end

    local function reopen_upper()
      local upper = review.fresh_review_state()({ review_type = 'by_commit', branch_key = 'upper', repo_key = 'repo' })
      upper:load_from_disk()
      upper:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
      return upper
    end

    it('does not adopt a record again after it was unmarked', function()
      run(function()
        local upper = adopted_by_upper()
        upper:remove_record('subj:src/a.lua')
        upper:save()

        eq(reopen_upper():get_record('subj:src/a.lua'), nil)
      end)
    end)

    it('does not adopt records again after a reset', function()
      run(function()
        local upper = adopted_by_upper()
        upper:reset()
        upper:save()

        eq(reopen_upper():get_record('subj:src/a.lua'), nil)
      end)
    end)

    it("keeps its own record over another branch's for the same commit", function()
      run(function()
        local sibling = new_state({ branch_key = 'own-sibling', repo_key = 'repo' })
        sibling:set_record('subj:src/a.lua', { 'theirs' }, false, { 'base' })
        sibling:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
        sibling:save()

        local current = new_state({ branch_key = 'own-current', repo_key = 'repo' })
        current:set_record('subj:src/a.lua', { 'mine' }, false, { 'base' })
        current:reconcile_change_ids({ item('subj:src/a.lua', 'src/a.lua', cid) })
        eq(current:get_record('subj:src/a.lua').lines, { 'mine' })
      end)
    end)
  end)
end)
