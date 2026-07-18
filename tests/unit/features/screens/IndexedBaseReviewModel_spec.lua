local IndexedReviewState = require('vgit.features.screens.IndexedReviewState')
local IndexedBaseReviewModel = require('vgit.features.screens.IndexedBaseReviewModel')

local eq = assert.are.same

-- Minimal concrete model: contents are injected directly, entries are static.
local TestModel = IndexedBaseReviewModel:extend()

function TestModel:constructor(opts)
  return IndexedBaseReviewModel.constructor(self, opts)
end

function TestModel:get_entry_key(entry)
  return entry.filepath
end

function TestModel:get_review_type()
  return 'by_file_indexed'
end

function TestModel:rebuild_entries() end

local FILE = 'foo.lua'

local function make_model(contents)
  local model = TestModel({ layout_type = 'unified' })
  model.state.reponame = '.'
  model.review_state = IndexedReviewState({ review_type = 'by_file_indexed' })
  model:set_contents(FILE, contents)
  return model
end

local function unseen_entry()
  return { filepath = FILE, type = 'unseen' }
end

local function seen_entry()
  return { filepath = FILE, type = 'seen' }
end

describe('IndexedBaseReviewModel reconcile:', function()
  before_each(function()
    -- state_store is module-global and keyed by branch/type; reset between tests
    IndexedReviewState({ review_type = 'by_file_indexed' }):reset()
  end)

  it('rebases the approved snapshot when the base gains unrelated changes', function()
    -- Approve the file's whole delta (other -> other_v2) on the old base
    local old_base = { 'fn get_address', 'body', 'other', 'tail' }
    local old_current = { 'fn get_address', 'body', 'other_v2', 'tail' }
    local model = make_model({ base = old_base, current = old_current })
    model:mark_file(unseen_entry())

    -- Restack: an ancestor commit renamed get_address underneath this one
    local new_base = { 'fn get_next_unused_address', 'body', 'other', 'tail' }
    local new_current = { 'fn get_next_unused_address', 'body', 'other_v2', 'tail' }
    model = make_model({ base = new_base, current = new_current })

    -- No phantom drift: unseen is empty, seen is exactly the approved delta
    local unseen = model:get_diff_for(unseen_entry())
    eq(#unseen.hunks, 0)

    local seen = model:get_diff_for(seen_entry())
    eq(#seen.hunks, 1)
    local removed, added = seen.hunks[1]:parse_diff()
    eq(removed, { 'other' })
    eq(added, { 'other_v2' })

    -- The record now tracks the new base
    local record = model.review_state:get_approved(FILE)
    eq(record.base_lines, new_base)
    eq(record.lines, new_current)
  end)

  it('reverts only the conflicted hunk to unseen, keeping the rest approved', function()
    -- Approve two hunks: k1 -> K1 and k2 -> K2
    local old_base = { 'alpha', 'k1', 'mid', 'k2', 'omega' }
    local old_current = { 'alpha', 'K1', 'mid', 'K2', 'omega' }
    local model = make_model({ base = old_base, current = old_current })
    model:mark_file(unseen_entry())

    -- Restack rewrote k2's region in the base; the commit still carries both deltas
    local new_base = { 'alpha', 'k1', 'mid', 'k2-rewritten', 'omega' }
    local new_current = { 'alpha', 'K1', 'mid', 'K2', 'omega' }
    model = make_model({ base = new_base, current = new_current })

    -- The conflicted hunk (k2) is back in unseen for re-review
    local unseen = model:get_diff_for(unseen_entry())
    eq(#unseen.hunks, 1)
    local removed, added = unseen.hunks[1]:parse_diff()
    eq(removed, { 'k2-rewritten' })
    eq(added, { 'K2' })

    -- The clean hunk (k1) is still approved
    local seen = model:get_diff_for(seen_entry())
    eq(#seen.hunks, 1)
    removed, added = seen.hunks[1]:parse_diff()
    eq(removed, { 'k1' })
    eq(added, { 'K1' })
  end)

  it('removes the record entirely when every approved hunk conflicts', function()
    local old_base = { 'a', 'b', 'c' }
    local old_current = { 'a', 'B', 'c' }
    local model = make_model({ base = old_base, current = old_current })
    model:mark_file(unseen_entry())

    -- The new base rewrote the approved hunk's region
    local new_base = { 'a', 'b-rewritten', 'c' }
    model = make_model({ base = new_base, current = { 'a', 'B', 'c' } })

    eq(model:get_reconciled_record(FILE, model:get_contents(unseen_entry())), nil)
    eq(model.review_state:get_approved(FILE), nil)
  end)

  it('does not stamp the current base onto a partial mark of a legacy record', function()
    -- Legacy record embodies an old base ('v0'); the live base has since
    -- drifted to 'v1'. diff(approved, current) shows a phantom v0->v1 hunk
    -- plus the real +C hunk.
    local model = make_model({ base = { 'v1', 'b' }, current = { 'v1', 'B', 'C' } })
    model.review_state:set_approved(FILE, { 'v0', 'B' }, false, nil)

    -- Mark only the real hunk (+C); the result still carries the stale 'v0'
    model:mark_selections(unseen_entry(), { { index = 2 } })

    -- The record must stay base-less: attaching the current base would make
    -- the stale content look like an approved reversion of the base's changes
    local record = model.review_state:get_approved(FILE)
    eq(record.lines, { 'v0', 'B', 'C' })
    eq(record.base_lines, nil)
  end)

  it('heals a legacy record when marking makes it match current', function()
    local base = { 'v1', 'b' }
    local model = make_model({ base = base, current = { 'v1', 'B', 'C' } })
    model.review_state:set_approved(FILE, { 'v0', 'B' }, false, nil)

    -- Marking every remaining hunk lands exactly on current: consistent by
    -- construction, so the record graduates to reconcilable
    model:mark_selections(unseen_entry(), { { index = 1 }, { index = 2 } })

    local record = model.review_state:get_approved(FILE)
    eq(record.lines, { 'v1', 'B', 'C' })
    eq(record.base_lines, base)
  end)

  it('keeps a legacy record base-less through a partial unmark', function()
    local model = make_model({ base = { 'a', 'b', 'x', 'c' }, current = { 'a', 'B', 'x', 'C' } })
    model.review_state:set_approved(FILE, { 'a', 'B', 'x', 'C' }, false, nil)

    -- Unmark the second seen hunk (C -> c); the rest stays approved
    model:unmark_selections(seen_entry(), { { index = 2 } })

    local record = model.review_state:get_approved(FILE)
    eq(record.lines, { 'a', 'B', 'x', 'c' })
    eq(record.base_lines, nil)
  end)

  it('titles a trunk review with its unpushed commit count', function()
    local model = make_model({ base = {}, current = {} })
    model.state.branch_name = 'master'
    model.state.base_branch = 'origin/master'

    model.state.unpushed_count = 4
    eq(model:get_list_title(), 'master (+4 unpushed commits) vs origin/master')

    model.state.unpushed_count = 1
    eq(model:get_list_title(), 'master (+1 unpushed commit) vs origin/master')

    model.state.unpushed_count = nil
    eq(model:get_list_title(), 'master (vs origin/master)')
  end)

  it('skips the unpushed count for non-trunk reviews', function()
    local model = make_model({ base = {}, current = {} })
    model.state.branch_name = 'feature'
    model.state.base_branch = 'master'

    -- Base is not origin/<branch>: returns before any git call (reponame unused)
    model:resolve_unpushed_count(nil)
    eq(model.state.unpushed_count, nil)
    eq(model:get_list_title(), 'feature (vs master)')
  end)

  it('leaves legacy records without base_lines untouched', function()
    local base = { 'a', 'b' }
    local model = make_model({ base = base, current = { 'a', 'B' } })
    -- Legacy record: no base_lines stored
    model.review_state:set_approved(FILE, { 'a', 'B' }, false, nil)

    local record = model:get_reconciled_record(FILE, model:get_contents(unseen_entry()))
    eq(record.lines, { 'a', 'B' })
    eq(record.base_lines, nil)

    -- Unseen diff is empty (approved == current), same as before the change
    local unseen = model:get_diff_for(unseen_entry())
    eq(#unseen.hunks, 0)
  end)
end)
