local Diff = require('vgit.core.Diff')
local loop = require('vgit.core.loop')
local git_repo = require('vgit.git.git_repo')
local git_show = require('vgit.git.git_show')
local git_hunks = require('vgit.git.git_hunks')
local git_branch = require('vgit.git.git_branch')
local ReviewState = require('vgit.features.screens.ReviewState')
local BaseReviewModel = require('vgit.features.screens.BaseReviewModel')

local Model = BaseReviewModel:extend()

-- Generate a key from commit hash and filename
local function make_key(commit_hash, filename)
  return string.format('%s:%s', commit_hash, filename)
end

-- Generate stable entry ID from commit, filename, and type
local function entry_id(commit_hash, filename, entry_type)
  return string.format('%s|%s|%s', commit_hash, filename, entry_type)
end

function Model:constructor(opts)
  local base = BaseReviewModel.constructor(self, opts)
  base.state.commits = {}
  base.state.commit_files = {} -- Cache: commit_hash -> files array
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
    branch_name = nil,
    list_entries = {},
    commits = {},
    commit_files = {},
    hunk_counts = {},
    layout_type = self.state.layout_type,
  }
end

-- Entry key for by-commit mode is "commit_hash:filename"
function Model:get_entry_key(entry)
  return make_key(entry.commit_hash, entry.filename)
end

function Model:get_review_type()
  return 'by_commit'
end

-- For by-commit mode, diff args are commit_hash and filename
function Model:get_diff_args(entry)
  return entry.commit_hash, entry.filename
end

function Model:get_commit_hash()
  local entry = self:get_entry()
  if not entry then return nil end
  return entry.commit_hash
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

  -- Get current branch name for state keying (persists across commits)
  local branch_name, branch_err = git_branch.current(reponame)
  if branch_err then return nil, branch_err end
  self.state.branch_name = branch_name

  -- Get merge-base
  local merge_base, mb_err = git_branch.merge_base(reponame, base_branch, 'HEAD')
  if mb_err then return nil, mb_err end
  self.state.merge_base = merge_base

  -- Initialize or restore review state
  self.review_state = ReviewState({
    base_branch = base_branch,
    branch_name = branch_name,
    review_type = self:get_review_type(),
  })
  -- Clear stale content_ids (HEAD may have changed since last session)
  -- Marks persist, content_ids will be recomputed from fresh diffs
  self.review_state:clear_content_ids()

  -- Get commits in the PR range
  local commits, commits_err = git_branch.commits_in_range(reponame, merge_base, 'HEAD')
  if commits_err then return nil, commits_err end

  if #commits == 0 then
    return nil, { string.format('Branch is the same as %s', base_branch) }
  end

  self.state.commits = commits

  -- Cache commit files in a single git command (batched for performance)
  local all_files, files_err = git_branch.all_commit_files(reponame, merge_base, 'HEAD')
  if files_err then return nil, files_err end
  self.state.commit_files = all_files or {}

  -- Preload diffs to get content_ids for accurate seen/unseen categorization
  for _, commit in ipairs(commits) do
    local files = self.state.commit_files[commit.hash] or {}
    for _, file in ipairs(files) do
      self:preload_diff(commit.hash, file.filename)
    end
  end

  self:rebuild_entries()
  return self.state.entries
end

-- Preload diff to populate content_ids cache (for accurate categorization)
function Model:preload_diff(commit_hash, filename)
  local cache_key = make_key(commit_hash, filename)
  if self.state.diffs[cache_key] then return end

  local reponame = self.state.reponame
  local parent_hash = commit_hash .. '^'

  local hunks = git_hunks.list(reponame, {
    parent = parent_hash,
    current = commit_hash,
    filename = filename,
  })

  local hunk_list = hunks or {}
  local count = #hunk_list > 0 and #hunk_list or 1
  self:set_hunk_count(cache_key, count)

  -- Compute and persist content_ids
  local content_ids = {}
  for _, hunk in ipairs(hunk_list) do
    content_ids[#content_ids + 1] = hunk:get_content_id()
  end
  if #content_ids == 0 then
    content_ids[1] = 'empty'
  end
  self.review_state:set_content_ids(cache_key, content_ids)
end

-- Rebuild entries after marking/unmarking (uses cached commit_files)
function Model:rebuild_entries()
  local commits = self.state.commits
  if not commits then return end

  -- Clear old list entries but keep diffs cached
  self.state.list_entries = {}

  local unseen_commits = {}
  local seen_commits = {}

  for _, commit in ipairs(commits) do
    local files = self.state.commit_files[commit.hash] or {}

    local unseen_files = {}
    local seen_files = {}

    for _, file in ipairs(files) do
      -- Mark key is filename only (marks are shared across commits)
      local mark_key = file.filename

      -- Get content_ids from local cache or persisted ReviewState
      local cache_key = make_key(commit.hash, file.filename)
      local cached_diff = self.state.diffs[cache_key]
      local content_ids = cached_diff and cached_diff._content_ids
        or self.review_state:get_content_ids(cache_key)

      local has_unseen = self.review_state:has_unseen_hunks(mark_key, content_ids)
      local has_seen = self.review_state:has_seen_hunks(mark_key, content_ids)

      local status = ReviewState.create_status(file.filename, file.status, file.old_filename)

      if has_unseen then
        local id = entry_id(commit.hash, file.filename, 'unseen')
        local data = {
          id = id,
          status = status,
          type = 'unseen',
          filename = file.filename,
          commit_hash = commit.hash,
          commit = commit,
        }
        self.state.list_entries[id] = data
        unseen_files[#unseen_files + 1] = data
      end

      if has_seen then
        local id = entry_id(commit.hash, file.filename, 'seen')
        local data = {
          id = id,
          status = status,
          type = 'seen',
          filename = file.filename,
          commit_hash = commit.hash,
          commit = commit,
        }
        self.state.list_entries[id] = data
        seen_files[#seen_files + 1] = data
      end
    end

    if #unseen_files > 0 then
      unseen_commits[#unseen_commits + 1] = { commit = commit, files = unseen_files }
    end

    if #seen_files > 0 then
      seen_commits[#seen_commits + 1] = { commit = commit, files = seen_files }
    end
  end

  local entries = {}
  if #seen_commits > 0 then
    entries[#entries + 1] = { title = 'Seen', commits = seen_commits }
  end
  if #unseen_commits > 0 then
    entries[#entries + 1] = { title = 'Unseen', commits = unseen_commits }
  end

  self.state.entries = entries
end

-- Get or create the full (unfiltered) diff for a commit+file
function Model:get_full_diff(commit_hash, filename)
  local cache_key = make_key(commit_hash, filename)

  if self.state.diffs[cache_key] then
    return self.state.diffs[cache_key]
  end

  local entry = self:get_entry()
  if not entry then return nil, { 'entry not found' } end

  local reponame = self.state.reponame
  local parent_hash = commit_hash .. '^'
  local layout_type = self:get_layout_type()

  -- Get hunks for this file in this commit
  local hunks, hunks_err = git_hunks.list(reponame, {
    parent = parent_hash,
    current = commit_hash,
    filename = filename,
  })
  if hunks_err then return nil, hunks_err end

  -- Get file content at commit
  local lines, lines_err = git_show.lines(reponame, filename, commit_hash)
  if lines_err then
    lines = {}
  end

  loop.free_textlock()

  -- Cache hunk count (computed lazily here instead of during fetch)
  local hunk_list = hunks or {}
  local count = #hunk_list > 0 and #hunk_list or 1
  self:set_hunk_count(cache_key, count)

  -- Compute content_ids for each hunk (for content-based mark persistence)
  local content_ids = {}
  for _, hunk in ipairs(hunk_list) do
    content_ids[#content_ids + 1] = hunk:get_content_id()
  end
  -- For empty/binary files, use a single 'empty' content_id
  if #content_ids == 0 then
    content_ids[1] = 'empty'
  end
  -- Persist content_ids in ReviewState (survives screen re-entry)
  -- Key by cache_key (commit:filename) since each commit has different hunks
  self.review_state:set_content_ids(cache_key, content_ids)

  local is_deleted = entry.status.first == 'D'
  local diff = Diff():generate(hunk_list, lines or {}, layout_type, { is_deleted = is_deleted })
  -- Store original data for filtered diff regeneration (avoid async calls later)
  diff._original_hunks = hunk_list
  diff._original_lines = lines or {}
  diff._is_deleted = is_deleted
  diff._content_ids = content_ids
  self.state.diffs[cache_key] = diff

  return diff
end

return Model
