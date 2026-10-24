local Diff = require('vgit.core.Diff')
local loop = require('vgit.core.loop')
local Object = require('vgit.core.Object')
local git_repo = require('vgit.git.git_repo')
local git_show = require('vgit.git.git_show')
local git_hunks = require('vgit.git.git_hunks')
local GitStatus = require('vgit.git.GitStatus')
local git_branch = require('vgit.git.git_branch')
local hunk_apply = require('vgit.features.screens.hunk_apply')
local record_keys = require('vgit.features.screens.record_keys')
local ReviewState = require('vgit.features.screens.ReviewState')
local persistence = require('vgit.features.screens.review_persistence')

--[[
  ReviewModel is the base of the review models (ProjectReviewByFileScreen
  and ProjectReviewByCommitScreen). A review is a list of items, each one
  reviewable (revision, file) pair, with three contents:

    base     - what the review diffs against (merge-base / commit parent)
    approved - the approved snapshot (ReviewState's record); without a
               record, approved == base
    current  - the review head's version (by-file) or the commit's (by-commit)

  The unseen view is diff(approved, current); the seen view is
  diff(base, approved). Marking applies hunks (or selected rows or lines) of
  the unseen diff onto the approved snapshot; unmarking reverse-applies hunks
  of the seen diff. Diffs are computed in-process from the contents loaded at
  fetch, so marking never shells out.

  A record also stores the base it was approved against, and is rebased onto
  the live base when that changes (see reconcile_record).

  An item is
    { id, record_key, filepath, old_filepath, status, commit?, base_spec,
      current_spec, contents = { base, current, current_deleted }, cache }
  where `id` is unique within the review, `record_key` names its record,
  the specs name its two sides' git objects, and `cache` holds what derives
  from its record (flags, and the seen and unseen Diffs). Subclasses list the
  items (`fetch_items`) and group entries for the list (`group_entries`).
  An entry is an item's seen or unseen view, as the list shows it.
]]

local ReviewModel = Object:extend()

-- Object contents by spec ('<hash>:<path>' or '<hash>^:<path>', full hashes
-- only), per review type. Specs name immutable objects, so these never go
-- stale. Each fetch keeps only the specs it asked for, which bounds this to
-- one review per type. Line arrays are shared between items, so nothing may
-- modify them.
local session_objects = { by_file = {}, by_commit = {} }

local MIN_SUBJECT_OVERLAP = 2

function ReviewModel:constructor(opts)
  return {
    state = { layout_type = opts.layout_type or 'unified' },
    review_state = nil,
  }
end

-- A new item for `file` (a changed-files entry: { filepath, old_filepath,
-- status }), completing `item`'s other fields
function ReviewModel.new_item(file, item)
  -- The constructor parses a porcelain line, which can't carry every path
  -- (it strips quotes), so the paths are set afterwards
  local status = GitStatus(string.format('%s  %s', file.status, file.filepath))
  status.filepath, status.old_filepath = file.filepath, file.old_filepath

  item.filepath, item.old_filepath, item.status = file.filepath, file.old_filepath, status
  item.cache = {}
  return item
end

-- The stored by-commit review (its branch key) that best covers HEAD's
-- commits, given the set of their subject keys (see record_keys). Subjects
-- survive rebases, so this follows a review across rebases wherever the
-- branch bookmark sits.
--
-- A review qualifies with `MIN_SUBJECT_OVERLAP` matching subjects, so a
-- coincidental one-commit overlap between branches doesn't count. A
-- single-commit stack could then never match, so a review also qualifies if
-- *all* its stored subjects match and they cover at least half of HEAD's
-- stack. The half-stack rule keeps one stray subject (e.g. records saved under a
-- misresolved key) from claiming a larger stack away from its bookmark.
--
-- Returns the qualifying branch with the most overlap, ties going to the most
-- recently used, or nil. Safe in fast event contexts.
function ReviewModel.branch_by_subjects(repo_key, head_subjects)
  local head_count = vim.tbl_count(head_subjects)
  if head_count == 0 then return nil end

  local best_key, best_overlap, best_mtime = nil, 0, 0
  for state_file, mtime in persistence.each_branch_state(repo_key, 'by_commit') do
    local overlap, stored, counted = 0, 0, {}
    for key in pairs(state_file.records) do
      local subject = record_keys.split(key)
      if subject and not counted[subject] then
        counted[subject] = true
        stored = stored + 1
        if head_subjects[subject] then overlap = overlap + 1 end
      end
    end

    local qualifies = overlap >= MIN_SUBJECT_OVERLAP
      or (overlap > 0 and overlap == stored and 2 * overlap >= head_count)
    if qualifies and (overlap > best_overlap or (overlap == best_overlap and mtime > best_mtime)) then
      best_key, best_overlap, best_mtime = state_file.branch_key, overlap, mtime
    end
  end
  return best_key
end

-- Resolve what to review (git_branch.review_target) and the repo key the
-- review persists under. For a detached jj HEAD no bookmark claims, the
-- branch is the stored review that covers HEAD's commits (see
-- branch_by_subjects). Returns target, repo_key, or nil, err.
local function resolve_target(reponame, base_arg)
  local repo_key = git_repo.get_name(reponame)
  local target, err = git_branch.review_target(reponame, base_arg, function(base, head)
    -- Keyed as the by-commit review keys them, repeats included
    local commits = git_branch.commits_in_range(reponame, base, head) or {}
    local messages = vim.tbl_map(function(commit) return commit.message end, commits)
    local subjects = {}
    for _, subject_key in ipairs(record_keys.subject_keys(messages)) do
      subjects[subject_key] = true
    end
    return ReviewModel.branch_by_subjects(repo_key, subjects)
  end)
  if not target then return nil, err end
  return target, repo_key
end

-- Load both sides of every item in one `git cat-file --batch`, through the
-- session object cache. A missing object means the file doesn't exist at
-- that revision (added / deleted side, or the parent of a root commit).
-- Returns nil, err if git fails.
function ReviewModel:load_contents(items)
  local cached, objects, misses = session_objects[self.review_type], {}, {}
  for _, item in ipairs(items) do
    for _, spec in ipairs({ item.base_spec, item.current_spec }) do
      if objects[spec] == nil then
        objects[spec] = cached[spec] or false
        if not objects[spec] then misses[#misses + 1] = spec end
      end
    end
  end

  if #misses > 0 then
    local results, err = git_show.lines_batch(self.state.reponame, misses)
    if err then return nil, err end
    for i, spec in ipairs(misses) do
      objects[spec] = results[i]
    end
  end
  session_objects[self.review_type] = objects

  for _, item in ipairs(items) do
    local base, current = objects[item.base_spec], objects[item.current_spec]
    item.contents = {
      base = base.lines or {},
      current = current.lines or {},
      current_deleted = current.missing == true,
    }
  end
end

-- Fetch the review: resolve its target, load its stored records, then list
-- its items and their contents. Must run in a coroutine. Returns the entries
-- (see get_entries), or nil, err.
function ReviewModel:fetch(base_arg)
  self.state = { layout_type = self.state.layout_type }

  loop.free_textlock()
  local reponame, repo_err = git_repo.discover()
  if repo_err then return nil, { 'Project has no .git folder' } end
  self.state.reponame = reponame

  local target, repo_key = resolve_target(reponame, base_arg)
  if not target then return nil, repo_key end
  self.state.base_branch = target.base
  self.state.branch_key = target.branch_key
  self.state.unpushed_count = target.unpushed_count

  git_branch.fetch_ref_if_stale(reponame, target.base)

  self.review_state = ReviewState({
    repo_key = repo_key,
    branch_key = target.branch_key,
    review_type = self.review_type,
  })
  self.review_state:load_from_disk()

  local items, err = self:fetch_items(target)
  if not items then return nil, err end
  if #items == 0 then return nil, { string.format('Branch is the same as %s', target.base) } end

  local _, load_err = self:load_contents(items)
  if load_err then return nil, load_err end

  self:set_items(items)
  return self.state.entries
end

-- Take `items`, with contents loaded, as the review's and build its entries
function ReviewModel:set_items(items)
  self.state.items = items
  -- The item behind every possible entry id
  self.state.entry_items = {}
  for _, item in ipairs(items) do
    self.state.entry_items[item.id .. '|seen'] = item
    self.state.entry_items[item.id .. '|unseen'] = item
  end
  self:rebuild_entries()
end

function ReviewModel:item_of(entry)
  return self.state.entry_items[entry.id]
end

-- The approved record for `item`, rebased onto its live base if the base
-- changed since approval (e.g. commits inserted or reordered below it).
-- Otherwise the base's changes would show as hunks in both views.
-- hunk_apply.rebase re-plays the approved delta hunk by hunk and drops the
-- hunks that no longer apply, which reverts just their delta to unseen. The
-- rebased record replaces the stored one, so this runs once per base change.
-- Every read of a record goes through here.
function ReviewModel:reconcile_record(item)
  local record = self.review_state:get_record(item.record_key)
  local base = item.contents.base
  if not record or hunk_apply.lines_equal(record.base_lines, base) then return record end

  local hunks = git_hunks.live(self.state.reponame, record.base_lines, record.lines) or {}
  local new_lines = hunk_apply.rebase(hunks, record.base_lines, base)

  if hunk_apply.lines_equal(new_lines, base) then
    self.review_state:remove_record(item.record_key)
    return nil
  end

  local deleted = record.deleted == true and #new_lines == 0
  self.review_state:set_record(item.record_key, new_lines, deleted, base)
  return self.review_state:get_record(item.record_key)
end

-- Whether `item` has seen content (approved != base) and unseen content
-- (approved != current). Presence flags (deleted or missing) can differ only
-- for empty contents, whose diff has nothing left to review, so this compares
-- lines only.
local function seen_flags(self, item)
  if item.cache.flags then return item.cache.flags end

  local record = self:reconcile_record(item)
  local flags = { has_seen = false, has_unseen = true }
  if record then
    local eq_base = hunk_apply.lines_equal(record.lines, item.contents.base)
    local eq_current = hunk_apply.lines_equal(record.lines, item.contents.current)
    -- A record equal to base survives only if a file with base == current
    -- (e.g. a pure rename) was marked seen. Keep it in Seen so it can be
    -- unmarked.
    flags = { has_seen = not eq_base or eq_current, has_unseen = not eq_current }
  end

  item.cache.flags = flags
  return flags
end

local function new_entry(self, item, entry_type)
  local entry = {
    id = item.id .. '|' .. entry_type,
    type = entry_type,
    filepath = item.filepath,
    old_filepath = item.old_filepath,
    status = item.status,
    commit = item.commit,
    commit_hash = item.commit and item.commit.hash,
  }
  self.state.entries_by_id[entry.id] = entry
  return entry
end

-- Rebuild the entries from the items' flags, after a mark changed them
function ReviewModel:rebuild_entries()
  self.state.entries_by_id = {}

  local seen, unseen = {}, {}
  for _, item in ipairs(self.state.items) do
    local flags = seen_flags(self, item)
    if flags.has_seen then seen[#seen + 1] = new_entry(self, item, 'seen') end
    if flags.has_unseen then unseen[#unseen + 1] = new_entry(self, item, 'unseen') end
  end

  local sections = {}
  for _, section in ipairs({ { 'seen', 'Seen', seen }, { 'unseen', 'Unseen', unseen } }) do
    local entry_type, title, entries = unpack(section)
    if #entries > 0 then
      local section = vim.tbl_extend('error', { type = entry_type, title = title }, self:group_entries(entries))
      sections[#sections + 1] = section
    end
  end
  self.state.entries = sections
end

-- Build the Diff rendering hunks against lines, and cache it as the item's
-- `entry_type` view
local function cache_diff(self, item, entry_type, hunks, lines, opts)
  local diff = Diff():generate(hunks, lines, self.state.layout_type, opts)
  item.cache[entry_type] = diff
  return diff
end

-- The diff for an entry:
--   unseen: diff(approved-or-base -> current), rendered on current content
--   seen:   diff(base -> approved), rendered on approved content
function ReviewModel:get_diff_for(entry)
  local item = self:item_of(entry)
  if item.cache[entry.type] then return item.cache[entry.type] end

  local contents = item.contents
  local record = self:reconcile_record(item)

  local old_lines, new_lines, new_deleted
  if entry.type == 'unseen' then
    old_lines = record and record.lines or contents.base
    new_lines = contents.current
    new_deleted = contents.current_deleted
  else
    old_lines = contents.base
    new_lines = record and record.lines or contents.base
    new_deleted = record and record.deleted or false
  end

  local hunks = git_hunks.live(self.state.reponame, old_lines, new_lines) or {}

  -- A deleted new side renders the old content with whole-file removal marks;
  -- everything else renders the new content with hunks against it.
  if new_deleted and #new_lines == 0 and #hunks > 0 then
    return cache_diff(self, item, entry.type, hunks, old_lines, { is_deleted = true })
  end
  return cache_diff(self, item, entry.type, hunks, new_lines)
end

function ReviewModel:get_diff()
  local entry = self:get_entry()
  if not entry then return nil, { 'entry not found' } end
  return self:get_diff_for(entry)
end

-- Convert screen selections ({ index, rows | lines }) into hunk_apply selections
local function to_hunk_selections(diff, selections)
  local result = {}
  for _, selection in ipairs(selections) do
    local hunk = diff.hunks[selection.index]
    if hunk then
      result[#result + 1] = { hunk = hunk, rows = selection.rows, lines = selection.lines }
    end
  end
  return result
end

-- Mark hunks (or selected rows or lines) of an unseen entry's diff as seen:
-- apply them onto the approved snapshot. selections: array of
-- { index = hunk index, rows | lines } (see hunk_apply), neither for the
-- whole hunk.
function ReviewModel:mark_selections(entry, selections)
  if entry.type ~= 'unseen' then return end

  local item = self:item_of(entry)
  local diff = self:get_diff_for(entry)
  local hunk_selections = to_hunk_selections(diff, selections)
  if #hunk_selections == 0 then return end

  local contents = item.contents
  local record = self:reconcile_record(item)
  local new_lines = hunk_apply.apply_selections(record and record.lines or contents.base, hunk_selections, 'apply')

  -- The snapshot represents "file deleted" only once it fully matches a
  -- deleted current side.
  local deleted = contents.current_deleted and hunk_apply.lines_equal(new_lines, contents.current)
  self.review_state:set_record(item.record_key, new_lines, deleted, contents.base)

  item.cache = {}
  -- Derive what's left of this diff instead of re-diffing, so marked lines
  -- stay put (see hunk_apply.remaining). A deleted current side keeps the
  -- whole-file removal rendering of get_diff_for.
  if not contents.current_deleted then
    cache_diff(self, item, 'unseen', hunk_apply.remaining(diff.hunks, hunk_selections, 'apply'), contents.current)
  end
  self:rebuild_entries()
end

-- Unmark hunks (or selected rows or lines) of a seen entry's diff:
-- reverse-apply them, rolling the approved snapshot back toward base.
function ReviewModel:unmark_selections(entry, selections)
  if entry.type ~= 'seen' then return end

  local item = self:item_of(entry)
  local record = self:reconcile_record(item)
  if not record then return end

  local diff = self:get_diff_for(entry)
  local hunk_selections = to_hunk_selections(diff, selections)
  if #hunk_selections == 0 then return end

  local base = item.contents.base
  local new_lines = hunk_apply.apply_selections(record.lines, hunk_selections, 'reverse')
  local deleted = record.deleted == true and #new_lines == 0
  if hunk_apply.lines_equal(new_lines, base) then
    self.review_state:remove_record(item.record_key)
  else
    self.review_state:set_record(item.record_key, new_lines, deleted, base)
  end

  item.cache = {}
  -- As in mark_selections: keep the remaining seen lines where they were
  if not deleted then
    cache_diff(self, item, 'seen', hunk_apply.remaining(diff.hunks, hunk_selections, 'reverse'), new_lines)
  end
  self:rebuild_entries()
end

-- Mark a whole file seen: approved := current
function ReviewModel:mark_file(entry)
  local item = self:item_of(entry)
  local contents = item.contents
  self.review_state:set_record(item.record_key, contents.current, contents.current_deleted, contents.base)

  item.cache = {}
  self:rebuild_entries()
end

-- Unmark a whole file: approved := base
function ReviewModel:unmark_file(entry)
  local item = self:item_of(entry)
  self.review_state:remove_record(item.record_key)

  item.cache = {}
  self:rebuild_entries()
end

function ReviewModel:reset_marks()
  self.review_state:reset()
  for _, item in ipairs(self.state.items) do
    item.cache = {}
  end
  self:rebuild_entries()
end

-- The list's sections, Seen first, each { type, title } plus the subclass's
-- grouping of its entries (see group_entries)
function ReviewModel:get_entries()
  return self.state.entries
end

function ReviewModel:set_entry_id(id)
  self.state.id = id
end

-- The current entry, or nil
function ReviewModel:get_entry()
  return self.state.entries_by_id and self.state.entries_by_id[self.state.id]
end

-- The entry with `id`, or nil
function ReviewModel:lookup(id)
  return self.state.entries_by_id and self.state.entries_by_id[id]
end

-- The id `entry`'s item has in the other section, whether or not it is
-- listed there (see lookup)
function ReviewModel:sibling_id(entry)
  return self:item_of(entry).id .. '|' .. (entry.type == 'seen' and 'unseen' or 'seen')
end

function ReviewModel:get_layout_type()
  return self.state.layout_type
end

function ReviewModel:get_review_state()
  return self.review_state
end

function ReviewModel:get_reponame()
  return self.state.reponame
end

-- Header for the review list: the branch key the review persists under, and
-- the base it's diffed against. A trunk review's branch key names the trunk,
-- but its diff runs past the trunk ref to HEAD, so the header also counts the
-- unpushed commits.
function ReviewModel:get_list_title()
  local state, count = self.state, self.state.unpushed_count
  if count then
    local plural = count == 1 and '' or 's'
    return string.format('%s (+%d unpushed commit%s) vs %s', state.branch_key, count, plural, state.base_branch)
  end
  return string.format('%s (vs %s)', state.branch_key, state.base_branch)
end

function ReviewModel:get_filepath()
  local entry = self:get_entry()
  return entry and entry.filepath
end

function ReviewModel:get_abs_filepath()
  local filepath = self:get_filepath()
  return filepath and string.format('%s/%s', self.state.reponame, filepath)
end

function ReviewModel:get_filetype()
  local entry = self:get_entry()
  return entry and entry.status.filetype
end

-- The full message (lines) of the review's commit `commit_hash`, or nil
function ReviewModel:get_commit_message(commit_hash)
  local commit = self.state.commits_by_hash and self.state.commits_by_hash[commit_hash]
  return commit and commit.body
end

-- The review's items, for `target` (see git_branch.review_target), with
-- contents still to load. Returns nil, err on failure.
function ReviewModel:fetch_items(target)
  error('fetch_items must be implemented by subclass')
end

-- The body of a section listing `entries` (in item order): by-file
-- { entries }, by-commit { commits }
function ReviewModel:group_entries(entries)
  error('group_entries must be implemented by subclass')
end

return ReviewModel
