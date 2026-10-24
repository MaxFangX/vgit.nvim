local ReviewState = require('vgit.features.screens.ReviewState')
local ReviewModel = require('vgit.features.screens.ReviewModel')

local eq = assert.are.same

-- Minimal concrete model: contents are injected directly, entries are static.
local TestModel = ReviewModel:extend()

function TestModel:constructor(opts)
  return ReviewModel.constructor(self, opts)
end

function TestModel:get_entry_key(entry)
  return entry.filepath
end

function TestModel:get_review_type()
  return 'by_file'
end

function TestModel:rebuild_entries() end

local FILE = 'foo.lua'

local function make_model(contents)
  local model = TestModel({ layout_type = 'unified' })
  model.state.reponame = '.'
  model.review_state = ReviewState({ review_type = 'by_file' })
  model:set_contents(FILE, contents)
  return model
end

local function unseen_entry()
  return { filepath = FILE, type = 'unseen' }
end

local function seen_entry()
  return { filepath = FILE, type = 'seen' }
end

describe('ReviewModel reconcile:', function()
  before_each(function()
    -- state_store is module-global and keyed by branch/type; reset between tests
    ReviewState({ review_type = 'by_file' }):reset()
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
    local record = model.review_state:get_record(FILE)
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

  it('shows nothing unseen once an approved insertion moves into the base', function()
    -- Approve all of a commit that inserts log() and x()
    local old_base = { 'fn a() {', '}', 'fn b() {', '}' }
    local current = { 'fn a() {', '  log()', '}', 'fn b() {', '  x()', '}' }
    local model = make_model({ base = old_base, current = current })
    model:mark_file(unseen_entry())

    -- log() is absorbed into the parent; the commit's content is unchanged
    model = make_model({ base = { 'fn a() {', '  log()', '}', 'fn b() {', '}' }, current = current })
    eq(#model:get_diff_for(unseen_entry()).hunks, 0)
    eq(model:get_diff_for(seen_entry()).hunks[1].diff, { '+  x()' })
  end)

  it('removes the record entirely when every approved hunk conflicts', function()
    local old_base = { 'a', 'b', 'c' }
    local old_current = { 'a', 'B', 'c' }
    local model = make_model({ base = old_base, current = old_current })
    model:mark_file(unseen_entry())

    -- The new base rewrote the approved hunk's region
    local new_base = { 'a', 'b-rewritten', 'c' }
    model = make_model({ base = new_base, current = { 'a', 'B', 'c' } })

    eq(model:reconcile_record(FILE, model:get_contents(unseen_entry())), nil)
    eq(model.review_state:get_record(FILE), nil)
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
end)
