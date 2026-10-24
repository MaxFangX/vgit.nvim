-- Not a module path: plenary runs specs without the repo root on package.path
local review = dofile('tests/helpers/review.lua')
local ReviewState = require('vgit.features.screens.ReviewState')
local ReviewModel = require('vgit.features.screens.ReviewModel')
local ByFileModel = require('vgit.features.screens.ProjectReviewByFileScreen.Model')
local hunk_apply = require('vgit.features.screens.hunk_apply')

local eq = assert.are.same

local FILE = 'foo.lua'

-- A by-file model of one modified file with the given contents
local function make_model(contents)
  local model = ByFileModel({ layout_type = 'unified' })
  model.state.reponame = '.'
  model.review_state = ReviewState({ review_type = 'by_file' })
  local item = ReviewModel.new_item({ filepath = FILE, status = 'M' }, { id = FILE, record_key = FILE })
  item.contents = contents
  model:set_items({ item })
  return model
end

local function unseen_entry()
  return { id = FILE .. '|unseen', filepath = FILE, type = 'unseen' }
end

local function seen_entry()
  return { id = FILE .. '|seen', filepath = FILE, type = 'seen' }
end

describe('ReviewModel reconcile:', function()
  before_each(function()
    -- state_store is module-global, so reset it between tests
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

    -- Unseen is empty, and seen is exactly the approved delta
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

    eq(model:reconcile_record(model.state.items[1]), nil)
    eq(model.review_state:get_record(FILE), nil)
  end)

  it('titles a trunk review with its unpushed commit count', function()
    local model = make_model({ base = {}, current = {} })
    model.state.branch_key = 'master'
    model.state.base_branch = 'origin/master'

    model.state.unpushed_count = 4
    eq(model:get_list_title(), 'master (+4 unpushed commits) vs origin/master')

    model.state.unpushed_count = 1
    eq(model:get_list_title(), 'master (+1 unpushed commit) vs origin/master')

    model.state.unpushed_count = nil
    eq(model:get_list_title(), 'master (vs origin/master)')
  end)
end)

describe('ReviewModel chained marking:', function()
  it('keeps both views consistent across chained partial marks and unmarks', function()
    local rand = review.random(1234)

    local function subset(n)
      local set = {}
      for i = 1, n do
        if rand(2) == 1 then set[i] = true end
      end
      return set
    end

    local function whole(hunks)
      return vim.tbl_map(function(hunk) return { hunk = hunk } end, hunks)
    end

    -- Each step marks or unmarks random hunks, rows or lines through the
    -- model, which then caches the remaining diff the next step selects from,
    -- as the screen does
    for _ = 1, 600 do
      ReviewState({ review_type = 'by_file' }):reset()
      local base, current = {}, {}
      for _ = 1, rand(25) - 1 do base[#base + 1] = 'l' .. rand(5) end
      for _ = 1, rand(25) - 1 do current[#current + 1] = 'l' .. rand(5) end
      local kind = rand(4)
      if kind == 1 then base = {} elseif kind == 2 then current = {} end
      local model = make_model({ base = base, current = current, current_deleted = kind == 2 })
      -- Contents are shared line arrays (see ReviewModel), so ops must not touch them
      local base_copy, current_copy = vim.deepcopy(base), vim.deepcopy(current)

      for _ = 1, 12 do
        local entry = rand(2) == 1 and unseen_entry() or seen_entry()
        local selections = {}
        for i, hunk in ipairs(model:get_diff_for(entry).hunks) do
          local removed, added = hunk:parse_diff()
          local choice = rand(4)
          if choice == 1 then
            selections[#selections + 1] = { index = i }
          elseif choice == 2 then
            selections[#selections + 1] = { index = i, rows = subset(math.max(#removed, #added)) }
          elseif choice == 3 then
            selections[#selections + 1] = { index = i, lines = { removed = subset(#removed), added = subset(#added) } }
          end
        end
        if entry.type == 'unseen' then
          model:mark_selections(entry, selections)
        else
          model:unmark_selections(entry, selections)
        end

        local record = model.review_state:get_record(FILE)
        local approved = record and record.lines or base
        local unseen = whole(model:get_diff_for(unseen_entry()).hunks)
        local seen = whole(model:get_diff_for(seen_entry()).hunks)
        eq(hunk_apply.apply_selections(approved, unseen, 'apply'), current)
        eq(hunk_apply.apply_selections(base, seen, 'apply'), approved)
      end
      eq(base, base_copy)
      eq(current, current_copy)
    end
  end)
end)
