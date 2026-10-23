local loop = require('vgit.core.loop')
local ReviewState = require('vgit.features.screens.ReviewState')
local change_id_rekey = require('vgit.features.screens.change_id_rekey')
local persistence = require('vgit.features.screens.ReviewPersistence')

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

local function new_state(opts)
  return ReviewState(vim.tbl_extend('force', { review_type = 'by_commit_indexed' }, opts))
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

    it('rekeys a record approved in an earlier session', function()
      run(function()
        local opts = { branch_name = 'reload', repo_name = 'repo' }
        local before = new_state(vim.tbl_extend('force', opts, { base_branch = 'a' }))
        before:set_approved('oldsubj:src/a.lua', { 'approved' }, false, { 'base' })
        before:reconcile_change_ids({ item('oldsubj:src/a.lua', 'src/a.lua', cid) })
        before:save()

        -- A different base_branch is a fresh session state reading the same file
        local after = new_state(vim.tbl_extend('force', opts, { base_branch = 'b' }))
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
        local data = persistence.load('repo', 'pool-current', 'by_commit_indexed')
        local entry = data.entries['subj:src/a.lua']
        eq(entry.change_id, cid)
        eq(persistence.read_object('repo', 'pool-current', entry.approved), { 'approved' })
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
