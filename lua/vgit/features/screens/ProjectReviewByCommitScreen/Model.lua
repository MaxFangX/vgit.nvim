local Diff = require('vgit.core.Diff')
local loop = require('vgit.core.loop')
local utils = require('vgit.core.utils')
local gitcli = require('vgit.git.gitcli')
local git_repo = require('vgit.git.git_repo')
local git_show = require('vgit.git.git_show')
local git_hunks = require('vgit.git.git_hunks')
local git_branch = require('vgit.git.git_branch')
local git_setting = require('vgit.settings.git')
local ReviewState = require('vgit.features.screens.ReviewState')
local BaseReviewModel = require('vgit.features.screens.BaseReviewModel')

local Model = BaseReviewModel:extend()

--[[
  HUNK KEYING STRATEGY

  Hunk marks use composite keys for persistence: mark_key:content_id.
  The mark_key portion differs by mode:

  BY FILE:   mark_key = filepath                   (e.g., "src/lib/Cargo.lock")
  BY COMMIT: mark_key = subject_hash:filepath      (e.g., "ccb4da92:src/lib/Cargo.lock")

  By-file uses filepath alone since each file appears once in the cumulative diff.
  By-commit adds subject_hash because the same file can appear in multiple commits
  with identical hunk content (e.g., Cargo.lock version bumps).

  Why subject_hash instead of commit_hash?
  - Commit hashes change on rebase, invalidating marks
  - Subjects typically survive rebases unchanged
  - FNV-1a hash keeps keys compact and avoids delimiter issues (subjects may contain colons)

  Trade-off: commits with identical subjects share marks (rare in practice).
]]

-- Generate cache key from commit hash and filepath (for diff caching)
local function make_key(commit_hash, filepath)
  return string.format('%s:%s', commit_hash, filepath)
end

-- Generate stable entry ID from commit, filepath, and type
local function entry_id(commit_hash, filepath, entry_type)
  return string.format('%s|%s|%s', commit_hash, filepath, entry_type)
end

-- Generate mark key from commit subject and filepath.
-- See "HUNK KEYING STRATEGY" comment above for rationale.
local function make_mark_key(commit_subject, filepath)
  local subject_hash = utils.str.fnv1a(vim.trim(commit_subject))
  return string.format('%s:%s', subject_hash, filepath)
end

function Model:constructor(opts)
  local base = BaseReviewModel.constructor(self, opts)
  base.state.commits = {}
  base.state.commit_files = {} -- Cache: commit_hash -> files array
  base.state.commit_messages = {} -- Cache: commit_hash -> message lines
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
    commit_messages = {},
    hunk_counts = {},
    layout_type = self.state.layout_type,
  }
end

-- Entry key for by-commit mode is "commit_hash:filepath"
function Model:get_entry_key(entry)
  return make_key(entry.commit_hash, entry.filepath)
end

function Model:get_review_type()
  return 'by_commit'
end

-- For by-commit mode, diff args are commit_hash and filepath
function Model:get_diff_args(entry)
  return entry.commit_hash, entry.filepath
end

function Model:get_mark_key(entry)
  return make_mark_key(entry.commit.message, entry.filepath)
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

  -- Async fetch if stale — notifies user to reopen if base was updated
  git_branch.fetch_ref_if_stale(reponame, base_branch)

  -- Get merge-base
  local merge_base, mb_err = git_branch.merge_base(reponame, base_branch, 'HEAD')
  if mb_err then return nil, mb_err end
  self.state.merge_base = merge_base

  -- Get repo name for persistence (from origin URL or directory name)
  local repo_name = git_repo.get_name(reponame)

  -- Initialize or restore review state
  self.review_state = ReviewState({
    base_branch = base_branch,
    branch_name = branch_name,
    review_type = self:get_review_type(),
    repo_name = repo_name,
  })
  -- Load persisted state from disk (must be called from coroutine context)
  self.review_state:load_from_disk()
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

  -- Preload commit messages (avoids async issues during render)
  for _, commit in ipairs(commits) do
    self:get_commit_message(commit.hash)
  end

  -- Cache commit files in a single git command (batched for performance)
  local all_files, files_err = git_branch.all_commit_files(reponame, merge_base, 'HEAD')
  if files_err then return nil, files_err end
  self.state.commit_files = all_files or {}

  -- Preload diffs in parallel for content_ids
  self:preload_diffs_parallel(commits)

  self:rebuild_entries()
  return self.state.entries
end

-- Build git diff args for a single file (mirrors git_hunks.list logic)
local function build_diff_args(reponame, commit_hash, filepath, old_filepath)
  local parent_hash = commit_hash .. '^'
  local args = {
    '-C', reponame,
    '--no-pager',
    '-c', 'core.safecrlf=false',
    'diff',
    '--color=never',
    string.format('--diff-algorithm=%s', git_setting:get('algorithm')),
    '--patch-with-raw',
    '--unified=0',
  }

  if old_filepath then
    -- Renamed file: diff parent:old_filepath against current:filepath
    args[#args + 1] = string.format('%s:%s', parent_hash, old_filepath)
    args[#args + 1] = string.format('%s:%s', commit_hash, filepath)
  else
    args[#args + 1] = parent_hash
    args[#args + 1] = commit_hash
    args[#args + 1] = '--'
    args[#args + 1] = filepath
  end

  return args
end

-- Build git show args for file content
local function build_show_args(reponame, commit_hash, filepath)
  return {
    '-C', reponame,
    'show',
    string.format('%s:%s', commit_hash, filepath),
  }
end


-- Preload all diffs in parallel
function Model:preload_diffs_parallel(commits)
  local reponame = self.state.reponame

  -- Collect all files to preload
  local jobs = {}
  for _, commit in ipairs(commits) do
    local files = self.state.commit_files[commit.hash] or {}
    for _, file in ipairs(files) do
      local cache_key = make_key(commit.hash, file.filepath)
      if not self.state.diffs[cache_key] then
        jobs[#jobs + 1] = {
          commit_hash = commit.hash,
          filepath = file.filepath,
          old_filepath = file.old_filepath,
          cache_key = cache_key,
        }
      end
    end
  end

  if #jobs == 0 then return 0 end

  -- Build all git commands (2 per file: diff + show)
  local commands = {}
  for _, job in ipairs(jobs) do
    commands[#commands + 1] = build_diff_args(reponame, job.commit_hash, job.filepath, job.old_filepath)
    commands[#commands + 1] = build_show_args(reponame, job.commit_hash, job.filepath)
  end

  -- Run all commands in parallel
  local results = gitcli.run_parallel(commands)

  -- Process results (pairs of diff + show for each job)
  for i, job in ipairs(jobs) do
    local diff_idx = (i - 1) * 2 + 1
    local show_idx = (i - 1) * 2 + 2

    local diff_result = results[diff_idx]
    local show_result = results[show_idx]

    local hunk_list = {}
    if diff_result and diff_result.result then
      hunk_list = git_hunks.parse(diff_result.result)
    end

    local count = #hunk_list > 0 and #hunk_list or 1
    self:set_hunk_count(job.cache_key, count)

    local file_lines = (show_result and show_result.result) or {}

    -- Compute content_ids
    local content_ids = {}
    for _, hunk in ipairs(hunk_list) do
      content_ids[#content_ids + 1] = hunk:get_content_id(file_lines, 5)
    end
    if #content_ids == 0 then
      content_ids[1] = 'empty'
    end
    self.review_state:set_content_ids(job.cache_key, content_ids)
  end

  return #jobs
end

-- Preload diff to populate content_ids cache (for accurate categorization)
function Model:preload_diff(commit_hash, filepath, old_filepath)
  local cache_key = make_key(commit_hash, filepath)
  if self.state.diffs[cache_key] then return end

  local reponame = self.state.reponame
  local parent_hash = commit_hash .. '^'

  local hunks = git_hunks.list(reponame, {
    parent = parent_hash,
    current = commit_hash,
    filepath = filepath,
    old_filepath = old_filepath,
  })

  local hunk_list = hunks or {}
  local count = #hunk_list > 0 and #hunk_list or 1
  self:set_hunk_count(cache_key, count)

  -- Fetch file content for context
  local lines = git_show.lines(reponame, filepath, commit_hash) or {}

  -- Compute and persist content_ids (5-line context disambiguates identical hunks in same file)
  local content_ids = {}
  for _, hunk in ipairs(hunk_list) do
    content_ids[#content_ids + 1] = hunk:get_content_id(lines, 5)
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
      local mark_key = make_mark_key(commit.message, file.filepath)

      -- Get content_ids from local cache or persisted ReviewState
      local cache_key = make_key(commit.hash, file.filepath)
      local cached_diff = self.state.diffs[cache_key]
      local content_ids = cached_diff and cached_diff._content_ids
        or self.review_state:get_content_ids(cache_key)

      local has_unseen = self.review_state:has_unseen_hunks(mark_key, content_ids)
      local has_seen = self.review_state:has_seen_hunks(mark_key, content_ids)

      local status = ReviewState.create_status(file.filepath, file.status, file.old_filepath)

      if has_unseen then
        local id = entry_id(commit.hash, file.filepath, 'unseen')
        local data = {
          id = id,
          status = status,
          type = 'unseen',
          filepath = file.filepath,
          old_filepath = file.old_filepath,
          commit_hash = commit.hash,
          commit = commit,
        }
        self.state.list_entries[id] = data
        unseen_files[#unseen_files + 1] = data
      end

      if has_seen then
        local id = entry_id(commit.hash, file.filepath, 'seen')
        local data = {
          id = id,
          status = status,
          type = 'seen',
          filepath = file.filepath,
          old_filepath = file.old_filepath,
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

-- Get the full commit message for a commit (cached)
function Model:get_commit_message(commit_hash)
  if not commit_hash then return nil end

  if self.state.commit_messages[commit_hash] then
    return self.state.commit_messages[commit_hash]
  end

  local lines, err = git_show.commit_message(self.state.reponame, commit_hash)
  if err then return nil end

  self.state.commit_messages[commit_hash] = lines
  return lines
end

-- Get or create the full (unfiltered) diff for a commit+file
function Model:get_full_diff(commit_hash, filepath)
  local cache_key = make_key(commit_hash, filepath)

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
    filepath = filepath,
    old_filepath = entry.old_filepath,
  })
  if hunks_err then return nil, hunks_err end

  -- Get file content at commit
  local lines, lines_err = git_show.lines(reponame, filepath, commit_hash)
  if lines_err then
    lines = {}
  end

  loop.free_textlock()

  -- Cache hunk count (computed lazily here instead of during fetch)
  local hunk_list = hunks or {}
  local count = #hunk_list > 0 and #hunk_list or 1
  self:set_hunk_count(cache_key, count)

  -- Compute content_ids for each hunk (for content-based mark persistence)
  -- 5-line context disambiguates identical hunks in same file
  local content_ids = {}
  for _, hunk in ipairs(hunk_list) do
    content_ids[#content_ids + 1] = hunk:get_content_id(lines, 5)
  end
  -- For empty/binary files, use a single 'empty' content_id
  if #content_ids == 0 then
    content_ids[1] = 'empty'
  end
  -- Persist content_ids in ReviewState (survives screen re-entry)
  -- Key by cache_key (commit:filepath) since each commit has different hunks
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
