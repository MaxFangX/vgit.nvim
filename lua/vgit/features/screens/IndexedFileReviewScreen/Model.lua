local loop = require('vgit.core.loop')
local gitcli = require('vgit.git.gitcli')
local git_repo = require('vgit.git.git_repo')
local git_show = require('vgit.git.git_show')
local git_branch = require('vgit.git.git_branch')
local jj = require('vgit.git.jj')
local ReviewState = require('vgit.features.screens.ReviewState')
local IndexedReviewState = require('vgit.features.screens.IndexedReviewState')
local IndexedBaseReviewModel = require('vgit.features.screens.IndexedBaseReviewModel')

--[[
  Indexed by-file review model. Each entry is a file diffed cumulatively from
  the merge-base to HEAD. Contents are preloaded with two `git show`s per file
  (merge-base and HEAD versions); all diffs derive from those in-process.
  mark_key = entry_key = filepath.
]]

local Model = IndexedBaseReviewModel:extend()

function Model:constructor(opts)
  local base = IndexedBaseReviewModel.constructor(self, opts)
  base.state.changed_files = {}
  return base
end

function Model:reset()
  self.state = {
    id = nil,
    entries = nil,
    reponame = nil,
    base_branch = self.state.base_branch,
    merge_base = nil,
    branch_name = nil,
    list_entries = {},
    changed_files = {},
    contents = {},
    diffs = {},
    seen_flags = {},
    mark_key_entries = {},
    layout_type = self.state.layout_type,
  }
end

-- Entry key for by-file mode is just the filepath
function Model:get_entry_key(entry)
  return entry.filepath
end

function Model:get_review_type()
  return 'by_file_indexed'
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

  -- Resolve the branch key and repo name for persistence.
  local branch_name, repo_name, branch_err = self:resolve_branch_name(reponame, base_branch)
  if branch_err then return nil, branch_err end
  self.state.branch_name = branch_name

  -- Async fetch if stale — notifies user to reopen if base was updated
  git_branch.fetch_ref_if_stale(reponame, base_branch)

  -- Get merge-base
  local merge_base, mb_err = git_branch.merge_base(reponame, base_branch, 'HEAD')
  if mb_err then return nil, mb_err end
  self.state.merge_base = merge_base

  -- Initialize or restore the index
  self.review_state = IndexedReviewState({
    base_branch = base_branch,
    branch_name = branch_name,
    review_type = self:get_review_type(),
    repo_name = repo_name,
  })
  -- Load persisted state from disk (must be called from coroutine context)
  self.review_state:load_from_disk()

  -- Get files changed between merge-base and HEAD
  local changed_files, files_err = git_branch.changed_files(reponame, merge_base, 'HEAD')
  if files_err then return nil, files_err end

  -- Drop jj conflict-artifact sidecars (.jjconflict-*), which aren't reviewable
  -- and can number in the thousands, dominating the preload below.
  changed_files = jj.filter_conflict_artifacts(changed_files)

  if #changed_files == 0 then
    return nil, { string.format('Branch is the same as %s', base_branch) }
  end

  self.state.changed_files = changed_files

  -- Preload base and current contents in parallel
  self:preload_contents_parallel(changed_files)

  self:rebuild_entries()
  return self.state.entries
end

-- Build git show args for a file's content at a revision
local function build_show_args(reponame, revision, filepath)
  return {
    '-C', reponame,
    'show',
    string.format('%s:%s', revision, filepath),
  }
end

-- Interpret a `git show` result: (lines, missing). A failed show means the
-- file doesn't exist at that revision (added / deleted side of the diff).
local function show_lines(result)
  if not result or result.err or not result.result then return {}, true end
  return result.result, false
end

-- Preload all contents in parallel (2 shows per file: merge-base + HEAD)
function Model:preload_contents_parallel(changed_files)
  local reponame = self.state.reponame
  local merge_base = self.state.merge_base

  local jobs = {}
  for _, file in ipairs(changed_files) do
    if not self.state.contents[file.filepath] then
      jobs[#jobs + 1] = file
    end
  end
  if #jobs == 0 then return end

  local commands = {}
  for _, file in ipairs(jobs) do
    commands[#commands + 1] = build_show_args(reponame, merge_base, file.old_filepath or file.filepath)
    commands[#commands + 1] = build_show_args(reponame, 'HEAD', file.filepath)
  end

  local results = gitcli.run_parallel(commands)

  for i, file in ipairs(jobs) do
    local base_lines = show_lines(results[(i - 1) * 2 + 1])
    local current_lines, current_deleted = show_lines(results[(i - 1) * 2 + 2])

    self:set_contents(file.filepath, {
      base = base_lines,
      current = current_lines,
      current_deleted = current_deleted,
    })
  end
end

-- Fetch contents for a single entry (fallback when the preload missed it)
function Model:load_contents(entry)
  local reponame = self.state.reponame
  local merge_base = self.state.merge_base

  local base_lines = git_show.lines(reponame, entry.old_filepath or entry.filepath, merge_base)
  local current_lines, current_err = git_show.lines(reponame, entry.filepath, 'HEAD')

  self:set_contents(entry.filepath, {
    base = base_lines or {},
    current = current_lines or {},
    current_deleted = current_err ~= nil,
  })
end

-- Generate stable entry ID from filepath and type
local function entry_id(filepath, entry_type)
  return string.format('%s|%s', filepath, entry_type)
end

-- Rebuild entries after marking/unmarking (uses stored changed_files)
function Model:rebuild_entries()
  local changed_files = self.state.changed_files
  if not changed_files then return end

  -- Clear old list entries but keep contents/diffs cached
  self.state.list_entries = {}

  local unseen_files = {}
  local seen_files = {}

  for _, file in ipairs(changed_files) do
    local status = ReviewState.create_status(file.filepath, file.status, file.old_filepath)
    local flags = self:get_seen_flags(file.filepath, file.filepath)

    if flags.has_unseen then
      local id = entry_id(file.filepath, 'unseen')
      local data = { id = id, status = status, type = 'unseen', filepath = file.filepath, old_filepath = file.old_filepath }
      self.state.list_entries[id] = data
      unseen_files[#unseen_files + 1] = data
    end

    if flags.has_seen then
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

return Model
