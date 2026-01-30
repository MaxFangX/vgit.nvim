local Diff = require('vgit.core.Diff')
local loop = require('vgit.core.loop')
local git_repo = require('vgit.git.git_repo')
local git_show = require('vgit.git.git_show')
local git_hunks = require('vgit.git.git_hunks')
local git_branch = require('vgit.git.git_branch')
local ReviewState = require('vgit.features.screens.ReviewState')
local BaseReviewModel = require('vgit.features.screens.BaseReviewModel')

local Model = BaseReviewModel:extend()

function Model:constructor(opts)
  local base = BaseReviewModel.constructor(self, opts)
  base.state.changed_files = {}
  return base
end

function Model:reset()
  self.state = {
    id = nil,
    diffs = {},
    entries = nil,
    reponame = nil,
    base_branch = self.state.base_branch,
    merge_base = nil,
    head_hash = nil,
    list_entries = {},
    changed_files = {},
    hunk_counts = {},
    layout_type = self.state.layout_type,
  }
end

-- Entry key for by-file mode is just the filename
function Model:get_entry_key(entry)
  return entry.filename
end

function Model:get_review_type()
  return 'by_file'
end

-- For by-file mode, diff args is just the filename
function Model:get_diff_args(entry)
  return entry.filename
end

function Model:fetch(base_branch_arg)
  self:reset()

  loop.free_textlock()
  local reponame, repo_err = git_repo.discover()
  if repo_err then return nil, { 'Project has no .git folder' } end
  self.state.reponame = reponame

  -- Detect or use provided base branch
  local base_branch
  if base_branch_arg and base_branch_arg ~= '' then
    base_branch = base_branch_arg
  else
    local detected, detect_err = git_branch.detect_base(reponame)
    if detect_err then return nil, detect_err end
    base_branch = detected
  end
  self.state.base_branch = base_branch

  -- Get HEAD hash for state keying
  local head_hash, head_err = git_branch.head(reponame)
  if head_err then return nil, head_err end
  self.state.head_hash = head_hash

  -- Get merge-base
  local merge_base, mb_err = git_branch.merge_base(reponame, base_branch, 'HEAD')
  if mb_err then return nil, mb_err end
  self.state.merge_base = merge_base

  -- Initialize or restore review state
  self.review_state = ReviewState({
    base_branch = base_branch,
    head_hash = head_hash,
    review_type = self:get_review_type(),
  })

  -- Get files changed between merge-base and HEAD
  local changed_files, files_err = git_branch.changed_files(reponame, merge_base, 'HEAD')
  if files_err then return nil, files_err end

  if #changed_files == 0 then
    return nil, { string.format('Branch is the same as %s', base_branch) }
  end

  self.state.changed_files = changed_files

  -- Hunk counts are computed lazily in get_diff() for performance
  self:rebuild_entries()
  return self.state.entries
end

-- Generate stable entry ID from filename and type
local function entry_id(filename, entry_type)
  return string.format('%s|%s', filename, entry_type)
end

-- Rebuild entries after marking/unmarking (uses stored changed_files)
function Model:rebuild_entries()
  local changed_files = self.state.changed_files
  if not changed_files then return end

  -- Clear old list entries but keep diffs cached
  self.state.list_entries = {}

  local unseen_files = {}
  local seen_files = {}

  for _, file in ipairs(changed_files) do
    local status = ReviewState.create_status(file.filename, file.status, file.old_filename)
    local key = file.filename

    -- Pass cached hunk count if available (check local cache then ReviewState)
    local cached_count = self.state.hunk_counts[key] or self.review_state:get_hunk_count(key)
    local has_unseen = self.review_state:has_unseen_hunks(key, cached_count)
    local has_seen = self.review_state:has_seen_hunks(key)

    if has_unseen then
      local id = entry_id(file.filename, 'unseen')
      local data = { id = id, status = status, type = 'unseen', filename = file.filename }
      self.state.list_entries[id] = data
      unseen_files[#unseen_files + 1] = data
    end

    if has_seen then
      local id = entry_id(file.filename, 'seen')
      local data = { id = id, status = status, type = 'seen', filename = file.filename }
      self.state.list_entries[id] = data
      seen_files[#seen_files + 1] = data
    end
  end

  local entries = {}
  if #seen_files > 0 then
    entries[#entries + 1] = { title = 'Seen', entries = seen_files }
  end
  if #unseen_files > 0 then
    entries[#entries + 1] = { title = 'Unseen', entries = unseen_files }
  end

  self.state.entries = entries
end

-- Get or create the full (unfiltered) diff for a file
function Model:get_full_diff(filename)
  if self.state.diffs[filename] then
    return self.state.diffs[filename]
  end

  local entry = self:get_entry()
  if not entry then return nil, { 'entry not found' } end

  local reponame = self.state.reponame
  local merge_base = self.state.merge_base
  local layout_type = self:get_layout_type()

  -- Get hunks for this file between merge-base and HEAD
  local hunks, hunks_err = git_hunks.list(reponame, {
    parent = merge_base,
    current = 'HEAD',
    filename = filename,
  })
  if hunks_err then return nil, hunks_err end

  -- Get file content at HEAD
  local lines, lines_err = git_show.lines(reponame, filename, 'HEAD')
  if lines_err then
    -- File might be deleted
    lines = {}
  end

  loop.free_textlock()

  -- Cache hunk count (computed lazily here instead of during fetch)
  local hunk_list = hunks or {}
  local count = #hunk_list > 0 and #hunk_list or 1
  self:set_hunk_count(filename, count)

  local is_deleted = entry.status.first == 'D'
  local diff = Diff():generate(hunk_list, lines or {}, layout_type, { is_deleted = is_deleted })
  -- Store original data for filtered diff regeneration (avoid async calls later)
  diff._original_hunks = hunk_list
  diff._original_lines = lines or {}
  diff._is_deleted = is_deleted
  self.state.diffs[filename] = diff

  return diff
end

return Model
