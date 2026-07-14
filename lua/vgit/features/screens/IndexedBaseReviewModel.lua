local Diff = require('vgit.core.Diff')
local Object = require('vgit.core.Object')
local git_repo = require('vgit.git.git_repo')
local git_hunks = require('vgit.git.git_hunks')
local git_branch = require('vgit.git.git_branch')
local hunk_apply = require('vgit.features.screens.hunk_apply')
local persistence = require('vgit.features.screens.IndexedReviewPersistence')

--[[
  IndexedBaseReviewModel contains shared logic for the indexed review models
  (IndexedFileReviewScreen and IndexedCommitReviewScreen).

  Unlike BaseReviewModel, which marks hunks seen by content hash, these models
  keep an *index*: an approved content snapshot per mark_key. Three contents
  exist per entry:

    base     - what the review diffs against (merge-base / commit parent)
    approved - the index; absent record means approved == base
    current  - HEAD version (by-file) or the commit's version (by-commit)

  The unseen view is diff(approved, current); the seen view is
  diff(base, approved). Marking applies hunks (or selected rows) of the unseen
  diff onto the approved snapshot; unmarking reverse-applies hunks of the seen
  diff. All diffs are computed from stored contents via git_hunks.live
  (in-process xdiff, git CLI only for very large files), so after the initial
  fetch marking rarely shells out.

  Subclasses must implement:
    - get_entry_key(entry) - key for content/diff caching
    - get_review_type() - 'by_file_indexed' or 'by_commit_indexed'
    - fetch(base_branch_arg) - fetches commits/files and preloads contents
    - rebuild_entries() - builds the entry structure
    - load_contents(entry) - fetch base/current contents for one entry

  Key concepts:
    - filepath: path relative to repo root
    - entry_key: content/diff cache key (by-file: filepath,
      by-commit: commit_hash:filepath)
    - mark_key: index storage key (by-file: filepath,
      by-commit: subject_hash:filepath — rebase-stable)
]]

local IndexedBaseReviewModel = Object:extend()

function IndexedBaseReviewModel:constructor(opts)
  return {
    state = {
      id = nil,
      entries = nil,
      reponame = nil,
      base_branch = nil,
      merge_base = nil,
      branch_name = nil,
      list_entries = {},
      contents = {},         -- entry_key -> { base, current, current_deleted }
      diffs = {},            -- entry_key .. '|' .. entry_type -> Diff
      seen_flags = {},       -- entry_key -> { has_seen, has_unseen }
      mark_key_entries = {}, -- mark_key -> set of entry_keys (for invalidation)
      layout_type = opts.layout_type or 'unified',
    },
    review_state = nil,
  }
end

function IndexedBaseReviewModel:get_layout_type()
  return self.state.layout_type
end

function IndexedBaseReviewModel:get_review_state()
  return self.review_state
end

-- Resolve the persistence keys for HEAD: the branch name the index is stored
-- under, plus the repo name. For a detached jj HEAD, the branch is resolved by
-- which stored review covers HEAD's commits (rebase-stable) before falling
-- back to topology, so the review follows the stack across rebases. Considers
-- both classic and indexed by-commit reviews.
-- Returns branch_name, repo_name, err.
function IndexedBaseReviewModel:resolve_branch_name(reponame, base_branch)
  local repo_name = git_repo.get_name(reponame)
  local branch_name, err = git_branch.current_persistent(reponame, function()
    return persistence.branch_by_subjects(repo_name, git_branch.head_subject_hashes(reponame, base_branch))
  end)
  return branch_name, repo_name, err
end

-- Header for the review list: the branch key the index persists under, plus
-- the base it's diffed against.
function IndexedBaseReviewModel:get_list_title()
  return string.format('%s (vs %s)', self.state.branch_name, self.state.base_branch)
end

function IndexedBaseReviewModel:set_entry_id(id)
  self.state.id = id
end

function IndexedBaseReviewModel:get_entry(id)
  if id then self.state.id = id end
  return self.state.list_entries[self.state.id]
end

function IndexedBaseReviewModel:get_entries()
  return self.state.entries
end

function IndexedBaseReviewModel:get_filepath()
  local entry = self:get_entry()
  if not entry then return nil end
  return entry.filepath
end

function IndexedBaseReviewModel:get_abs_filepath()
  local reponame = self.state.reponame
  local filepath = self:get_filepath()
  if not filepath then return nil end

  return string.format('%s/%s', reponame, filepath)
end

function IndexedBaseReviewModel:get_filetype()
  local entry = self:get_entry()
  if not entry then return nil end
  return entry.status.filetype
end

-- Get mark key for an entry (by-file: filepath; by-commit overrides)
function IndexedBaseReviewModel:get_mark_key(entry)
  return entry.filepath
end

-- Store fetched contents for an entry_key
function IndexedBaseReviewModel:set_contents(entry_key, contents)
  self.state.contents[entry_key] = contents
end

-- Get contents for an entry, fetching lazily if the preload missed it
function IndexedBaseReviewModel:get_contents(entry)
  local entry_key = self:get_entry_key(entry)
  local contents = self.state.contents[entry_key]
  if contents then return contents end

  self:load_contents(entry)
  return self.state.contents[entry_key]
end

-- Track which entry_keys derive from a mark_key so mark ops can invalidate them
local function track_mark_key(self, mark_key, entry_key)
  local entries = self.state.mark_key_entries[mark_key]
  if not entries then
    entries = {}
    self.state.mark_key_entries[mark_key] = entries
  end
  entries[entry_key] = true
end

-- Compare an approved record against fetched contents. Content-only:
-- presence flags (deleted/missing) could differ only for empty contents,
-- where every reachable pairing (rolled-back add vs absent base, approved
-- deletion vs deleted current, empty file) is correctly "equal" — an empty
-- diff has nothing left to review. The record's deleted flag is kept solely
-- for rendering the seen view.
local function record_equals(record, lines)
  return hunk_apply.lines_equal(record.lines, lines)
end

-- Categorize an entry: does it have seen content (approved != base) and/or
-- unseen content (approved != current)? Cached per entry_key; invalidated
-- when the entry's mark_key index changes.
function IndexedBaseReviewModel:get_seen_flags(entry_key, mark_key)
  local cached = self.state.seen_flags[entry_key]
  if cached then return cached end

  track_mark_key(self, mark_key, entry_key)

  local contents = self.state.contents[entry_key]
  local record = self.review_state and self.review_state:get_approved(mark_key)

  local flags
  if not record or not contents then
    -- No index record: everything unseen. (Missing contents: conservative.)
    flags = { has_seen = record ~= nil, has_unseen = true }
  else
    local eq_base = record_equals(record, contents.base)
    local eq_current = record_equals(record, contents.current)
    -- eq_base with a record only happens when base == current (e.g. pure
    -- rename) was marked seen; keep it visible in Seen so it can be unmarked.
    flags = { has_seen = not eq_base or eq_current, has_unseen = not eq_current }
  end

  self.state.seen_flags[entry_key] = flags
  return flags
end

-- Get the diff for an entry:
--   unseen: diff(approved-or-base -> current), rendered on current content
--   seen:   diff(base -> approved), rendered on approved content
function IndexedBaseReviewModel:get_diff_for(entry)
  local entry_key = self:get_entry_key(entry)
  local cache_key = string.format('%s|%s', entry_key, entry.type)
  if self.state.diffs[cache_key] then return self.state.diffs[cache_key] end

  local contents = self:get_contents(entry)
  if not contents then return nil, { 'failed to load file contents' } end

  local mark_key = self:get_mark_key(entry)
  track_mark_key(self, mark_key, entry_key)
  local record = self.review_state and self.review_state:get_approved(mark_key)

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
  local layout_type = self:get_layout_type()

  -- A deleted new side renders the old content with whole-file removal marks;
  -- everything else renders the new content with hunks against it.
  local diff
  if new_deleted and #new_lines == 0 and #hunks > 0 then
    diff = Diff():generate(hunks, old_lines, layout_type, { is_deleted = true })
  else
    diff = Diff():generate(hunks, new_lines, layout_type)
  end

  diff.entry_type = entry.type
  diff.mark_key = mark_key
  self.state.diffs[cache_key] = diff
  return diff
end

function IndexedBaseReviewModel:get_diff()
  local entry = self:get_entry()
  if not entry then return nil, { 'entry not found' } end
  return self:get_diff_for(entry)
end

-- Drop cached diffs and categorization for every entry deriving from mark_key
function IndexedBaseReviewModel:invalidate_mark_key(mark_key)
  local entries = self.state.mark_key_entries[mark_key]
  if not entries then return end

  for entry_key in pairs(entries) do
    self.state.seen_flags[entry_key] = nil
    self.state.diffs[entry_key .. '|seen'] = nil
    self.state.diffs[entry_key .. '|unseen'] = nil
  end
end

-- Convert screen selections ({ index, rows }) into hunk_apply selections
local function to_hunk_selections(diff, selections)
  local result = {}
  for _, selection in ipairs(selections) do
    local hunk = diff.hunks[selection.index]
    if hunk then
      result[#result + 1] = { hunk = hunk, rows = selection.rows }
    end
  end
  return result
end

-- Mark hunks (or selected rows) of the current unseen diff as seen: apply
-- them onto the approved snapshot. selections: array of
-- { index = hunk index, rows = set of row indices or nil for the whole hunk }.
function IndexedBaseReviewModel:mark_selections(entry, selections)
  if not self.review_state or entry.type ~= 'unseen' then return end

  local diff = self:get_diff_for(entry)
  if not diff or #(diff.hunks or {}) == 0 then return end

  local hunk_selections = to_hunk_selections(diff, selections)
  if #hunk_selections == 0 then return end

  local contents = self:get_contents(entry)
  local mark_key = self:get_mark_key(entry)
  local record = self.review_state:get_approved(mark_key)
  local old_lines = record and record.lines or contents.base

  local new_lines = hunk_apply.apply_selections(old_lines, hunk_selections, 'apply')

  -- The snapshot represents "file deleted" only once it fully matches a
  -- deleted current side.
  local deleted = contents.current_deleted == true and hunk_apply.lines_equal(new_lines, contents.current)
  self.review_state:set_approved(mark_key, new_lines, deleted)

  self:invalidate_mark_key(mark_key)
  self:rebuild_entries()
end

-- Unmark hunks (or selected rows) of the current seen diff: reverse-apply
-- them, rolling the approved snapshot back toward base.
function IndexedBaseReviewModel:unmark_selections(entry, selections)
  if not self.review_state or entry.type ~= 'seen' then return end

  local mark_key = self:get_mark_key(entry)
  local record = self.review_state:get_approved(mark_key)
  if not record then return end

  local diff = self:get_diff_for(entry)
  if not diff or #(diff.hunks or {}) == 0 then return end

  local hunk_selections = to_hunk_selections(diff, selections)
  if #hunk_selections == 0 then return end

  local contents = self:get_contents(entry)
  local new_lines = hunk_apply.apply_selections(record.lines, hunk_selections, 'reverse')
  local deleted = record.deleted == true and #new_lines == 0

  if hunk_apply.lines_equal(new_lines, contents.base) then
    self.review_state:remove_approved(mark_key)
  else
    self.review_state:set_approved(mark_key, new_lines, deleted)
  end

  self:invalidate_mark_key(mark_key)
  self:rebuild_entries()
end

-- Mark a whole file seen: approved := current
function IndexedBaseReviewModel:mark_file(entry)
  if not self.review_state then return end

  local contents = self:get_contents(entry)
  if not contents then return end

  local mark_key = self:get_mark_key(entry)
  self.review_state:set_approved(mark_key, contents.current, contents.current_deleted)

  self:invalidate_mark_key(mark_key)
  self:rebuild_entries()
end

-- Unmark a whole file: approved := base
function IndexedBaseReviewModel:unmark_file(entry)
  if not self.review_state then return end

  local mark_key = self:get_mark_key(entry)
  self.review_state:remove_approved(mark_key)

  self:invalidate_mark_key(mark_key)
  self:rebuild_entries()
end

function IndexedBaseReviewModel:reset_marks()
  if not self.review_state then return end
  self.review_state:reset()
  self.state.diffs = {}
  self.state.seen_flags = {}
  self:rebuild_entries()
end

-- Abstract methods - subclasses must implement
function IndexedBaseReviewModel:get_entry_key(entry)
  error('get_entry_key must be implemented by subclass')
end

function IndexedBaseReviewModel:get_review_type()
  error('get_review_type must be implemented by subclass')
end

function IndexedBaseReviewModel:fetch(base_branch_arg)
  error('fetch must be implemented by subclass')
end

function IndexedBaseReviewModel:rebuild_entries()
  error('rebuild_entries must be implemented by subclass')
end

function IndexedBaseReviewModel:load_contents(entry)
  error('load_contents must be implemented by subclass')
end

return IndexedBaseReviewModel
