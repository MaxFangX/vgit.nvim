local Diff = require('vgit.core.Diff')
local loop = require('vgit.core.loop')
local gitcli = require('vgit.git.gitcli')
local git_repo = require('vgit.git.git_repo')
local git_show = require('vgit.git.git_show')
local git_hunks = require('vgit.git.git_hunks')
local git_branch = require('vgit.git.git_branch')
local git_setting = require('vgit.settings.git')
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
    branch_name = nil,
    list_entries = {},
    changed_files = {},
    hunk_counts = {},
    layout_type = self.state.layout_type,
  }
end

-- Entry key for by-file mode is just the filepath
function Model:get_entry_key(entry)
  return entry.filepath
end

function Model:get_review_type()
  return 'by_file'
end

-- For by-file mode, diff args is just the filepath
function Model:get_diff_args(entry)
  return entry.filepath
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

  -- Get current branch name for state keying (survives rebases)
  local branch_name, branch_err = git_branch.current_persistent(reponame)
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

  -- Get files changed between merge-base and HEAD
  local changed_files, files_err = git_branch.changed_files(reponame, merge_base, 'HEAD')
  if files_err then return nil, files_err end

  if #changed_files == 0 then
    return nil, { string.format('Branch is the same as %s', base_branch) }
  end

  self.state.changed_files = changed_files

  -- Preload diffs in parallel to get content_ids for accurate categorization
  self:preload_diffs_parallel(changed_files)

  self:rebuild_entries()
  return self.state.entries
end

-- Build git diff args for a single file
local function build_diff_args(reponame, merge_base, filepath, old_filepath)
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
    -- Renamed file: diff merge_base:old_filepath against HEAD:filepath
    args[#args + 1] = string.format('%s:%s', merge_base, old_filepath)
    args[#args + 1] = string.format('%s:%s', 'HEAD', filepath)
  else
    args[#args + 1] = merge_base
    args[#args + 1] = 'HEAD'
    args[#args + 1] = '--'
    args[#args + 1] = filepath
  end

  return args
end

-- Build git show args for file content
local function build_show_args(reponame, filepath)
  return {
    '-C', reponame,
    'show',
    string.format('%s:%s', 'HEAD', filepath),
  }
end


-- Preload all diffs in parallel
function Model:preload_diffs_parallel(changed_files)
  local reponame = self.state.reponame
  local merge_base = self.state.merge_base

  -- Collect all files to preload
  local jobs = {}
  for _, file in ipairs(changed_files) do
    if not self.state.diffs[file.filepath] then
      jobs[#jobs + 1] = {
        filepath = file.filepath,
        old_filepath = file.old_filepath,
      }
    end
  end

  if #jobs == 0 then return end

  -- Build all git commands (2 per file: diff + show)
  local commands = {}
  for _, job in ipairs(jobs) do
    commands[#commands + 1] = build_diff_args(reponame, merge_base, job.filepath, job.old_filepath)
    commands[#commands + 1] = build_show_args(reponame, job.filepath)
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
    self:set_hunk_count(job.filepath, count)

    local file_lines = (show_result and show_result.result) or {}

    -- Compute content_ids
    local content_ids = {}
    for _, hunk in ipairs(hunk_list) do
      content_ids[#content_ids + 1] = hunk:get_content_id(file_lines, 5)
    end
    if #content_ids == 0 then
      content_ids[1] = 'empty'
    end
    self.review_state:set_content_ids(job.filepath, content_ids)
  end
end

-- Preload diff to populate content_ids cache (for accurate categorization)
function Model:preload_diff(filepath, old_filepath)
  if self.state.diffs[filepath] then return end

  local reponame = self.state.reponame
  local merge_base = self.state.merge_base
  local layout_type = self:get_layout_type()

  local hunks = git_hunks.list(reponame, {
    parent = merge_base,
    current = 'HEAD',
    filepath = filepath,
    old_filepath = old_filepath,
  })

  local hunk_list = hunks or {}
  local count = #hunk_list > 0 and #hunk_list or 1
  self:set_hunk_count(filepath, count)

  -- Fetch file content for context
  local lines = git_show.lines(reponame, filepath, 'HEAD') or {}

  -- Compute and persist content_ids (5-line context disambiguates identical hunks in same file)
  local content_ids = {}
  for _, hunk in ipairs(hunk_list) do
    content_ids[#content_ids + 1] = hunk:get_content_id(lines, 5)
  end
  if #content_ids == 0 then
    content_ids[1] = 'empty'
  end
  self.review_state:set_content_ids(filepath, content_ids)
end

-- Generate stable entry ID from filepath and type
local function entry_id(filepath, entry_type)
  return string.format('%s|%s', filepath, entry_type)
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
    local status = ReviewState.create_status(file.filepath, file.status, file.old_filepath)
    -- Mark key is just the filepath
    local mark_key = file.filepath

    -- Get content_ids from local cache or persisted ReviewState
    local cached_diff = self.state.diffs[mark_key]
    local content_ids = cached_diff and cached_diff._content_ids
      or self.review_state:get_content_ids(mark_key)

    local has_unseen = self.review_state:has_unseen_hunks(mark_key, content_ids)
    local has_seen = self.review_state:has_seen_hunks(mark_key, content_ids)

    if has_unseen then
      local id = entry_id(file.filepath, 'unseen')
      local data = { id = id, status = status, type = 'unseen', filepath = file.filepath, old_filepath = file.old_filepath }
      self.state.list_entries[id] = data
      unseen_files[#unseen_files + 1] = data
    end

    if has_seen then
      local id = entry_id(file.filepath, 'seen')
      local data = { id = id, status = status, type = 'seen', filepath = file.filepath, old_filepath = file.old_filepath }
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
function Model:get_full_diff(filepath)
  if self.state.diffs[filepath] then
    return self.state.diffs[filepath]
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
    filepath = filepath,
    old_filepath = entry.old_filepath,
  })
  if hunks_err then return nil, hunks_err end

  -- Get file content at HEAD
  local lines, lines_err = git_show.lines(reponame, filepath, 'HEAD')
  if lines_err then
    -- File might be deleted
    lines = {}
  end

  loop.free_textlock()

  -- Cache hunk count (computed lazily here instead of during fetch)
  local hunk_list = hunks or {}
  local count = #hunk_list > 0 and #hunk_list or 1
  self:set_hunk_count(filepath, count)

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
  self.review_state:set_content_ids(filepath, content_ids)

  local is_deleted = entry.status.first == 'D'
  local diff = Diff():generate(hunk_list, lines or {}, layout_type, { is_deleted = is_deleted })
  -- Store original data for filtered diff regeneration (avoid async calls later)
  diff._original_hunks = hunk_list
  diff._original_lines = lines or {}
  diff._is_deleted = is_deleted
  diff._content_ids = content_ids
  self.state.diffs[filepath] = diff

  return diff
end

return Model
