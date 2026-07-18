local loop = require('vgit.core.loop')
local utils = require('vgit.core.utils')
local gitcli = require('vgit.git.gitcli')
local git_repo = require('vgit.git.git_repo')
local git_show = require('vgit.git.git_show')
local git_branch = require('vgit.git.git_branch')
local jj = require('vgit.git.jj')
local ReviewState = require('vgit.features.screens.ReviewState')
local IndexedReviewState = require('vgit.features.screens.IndexedReviewState')
local IndexedBaseReviewModel = require('vgit.features.screens.IndexedBaseReviewModel')

--[[
  Indexed by-commit review model. Each entry is a (commit, file) pair diffed
  against the commit's parent. Contents are preloaded with two `git show`s per
  pair (parent and commit versions); all diffs derive from those in-process.

  KEYING (mirrors ProjectReviewByCommitScreen)

  entry_key = commit_hash:filepath   (content/diff caching; hash-exact)
  mark_key  = subject_hash:filepath  (index storage; rebase-stable)

  Commit hashes change on rebase but subjects typically survive, so the
  approved snapshot follows the commit across rebases/absorbs — which is the
  whole point: after a fixup is absorbed, diff(approved, new commit content)
  shows only the delta beyond what was already approved.

  Trade-off: commits with identical subjects share an index entry (rare).
]]

-- Generate cache key from commit hash and filepath (for content/diff caching)
local function make_key(commit_hash, filepath)
  return string.format('%s:%s', commit_hash, filepath)
end

-- Generate stable entry ID from commit, filepath, and type
local function entry_id(commit_hash, filepath, entry_type)
  return string.format('%s|%s|%s', commit_hash, filepath, entry_type)
end

-- Generate mark key from commit subject and filepath.
local function make_mark_key(commit_subject, filepath)
  local subject_hash = utils.str.fnv1a(vim.trim(commit_subject))
  return string.format('%s:%s', subject_hash, filepath)
end

local Model = IndexedBaseReviewModel:extend()

function Model:constructor(opts)
  local base = IndexedBaseReviewModel.constructor(self, opts)
  base.state.commits = {}
  base.state.commit_files = {} -- Cache: commit_hash -> files array
  base.state.commit_messages = {} -- Cache: commit_hash -> message lines
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
    commits = {},
    commit_files = {},
    commit_messages = {},
    contents = {},
    diffs = {},
    seen_flags = {},
    mark_key_entries = {},
    layout_type = self.state.layout_type,
  }
end

-- Entry key for by-commit mode is "commit_hash:filepath"
function Model:get_entry_key(entry)
  return make_key(entry.commit_hash, entry.filepath)
end

function Model:get_review_type()
  return 'by_commit_indexed'
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

  -- Resolve the branch key and repo name for persistence.
  local branch_name, repo_name, branch_err = self:resolve_branch_name(reponame, base_branch)
  if branch_err then return nil, branch_err end
  self.state.branch_name = branch_name
  self:resolve_unpushed_count(reponame)

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

  -- Get commits in the PR range
  local commits, commits_err = git_branch.commits_in_range(reponame, merge_base, 'HEAD')
  if commits_err then return nil, commits_err end

  if #commits == 0 then
    return nil, { string.format('Branch is the same as %s', base_branch) }
  end

  self.state.commits = commits

  -- Preload every commit's full message in one batched git call (avoids N
  -- sequential `git show` calls and async issues during render).
  self.state.commit_messages = git_branch.all_commit_messages(reponame, merge_base, 'HEAD') or {}

  -- Cache commit files in a single git command (batched for performance)
  local all_files, files_err = git_branch.all_commit_files(reponame, merge_base, 'HEAD')
  if files_err then return nil, files_err end
  self.state.commit_files = all_files or {}
  -- Drop jj conflict-artifact sidecars (.jjconflict-*), which aren't reviewable
  -- and can number in the thousands, dominating the preload below.
  for hash, files in pairs(self.state.commit_files) do
    self.state.commit_files[hash] = jj.filter_conflict_artifacts(files)
  end

  -- Preload parent and commit contents in parallel
  self:preload_contents_parallel(commits)

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
-- file doesn't exist at that revision (added / deleted side of the diff, or
-- the parent of a root commit).
local function show_lines(result)
  if not result or result.err or not result.result then return {}, true end
  return result.result, false
end

-- Preload all contents in parallel (2 shows per commit-file: parent + commit)
function Model:preload_contents_parallel(commits)
  local reponame = self.state.reponame

  local jobs = {}
  for _, commit in ipairs(commits) do
    local files = self.state.commit_files[commit.hash] or {}
    for _, file in ipairs(files) do
      local cache_key = make_key(commit.hash, file.filepath)
      if not self.state.contents[cache_key] then
        jobs[#jobs + 1] = {
          commit_hash = commit.hash,
          filepath = file.filepath,
          old_filepath = file.old_filepath,
          cache_key = cache_key,
        }
      end
    end
  end
  if #jobs == 0 then return end

  local commands = {}
  for _, job in ipairs(jobs) do
    commands[#commands + 1] = build_show_args(reponame, job.commit_hash .. '^', job.old_filepath or job.filepath)
    commands[#commands + 1] = build_show_args(reponame, job.commit_hash, job.filepath)
  end

  local results = gitcli.run_parallel(commands)

  for i, job in ipairs(jobs) do
    local base_lines = show_lines(results[(i - 1) * 2 + 1])
    local current_lines, current_deleted = show_lines(results[(i - 1) * 2 + 2])

    self:set_contents(job.cache_key, {
      base = base_lines,
      current = current_lines,
      current_deleted = current_deleted,
    })
  end
end

-- Fetch contents for a single entry (fallback when the preload missed it)
function Model:load_contents(entry)
  local reponame = self.state.reponame
  local parent_hash = entry.commit_hash .. '^'

  local base_lines = git_show.lines(reponame, entry.old_filepath or entry.filepath, parent_hash)
  local current_lines, current_err = git_show.lines(reponame, entry.filepath, entry.commit_hash)

  self:set_contents(self:get_entry_key(entry), {
    base = base_lines or {},
    current = current_lines or {},
    current_deleted = current_err ~= nil,
  })
end

-- Rebuild entries after marking/unmarking (uses cached commit_files)
function Model:rebuild_entries()
  local commits = self.state.commits
  if not commits then return end

  -- Clear old list entries but keep contents/diffs cached
  self.state.list_entries = {}

  local unseen_commits = {}
  local seen_commits = {}

  -- `i` is the commit's position from the diff base to HEAD (commits are
  -- `--reverse`-ordered), used as a stable index in the list view.
  for i, commit in ipairs(commits) do
    local files = self.state.commit_files[commit.hash] or {}

    local unseen_files = {}
    local seen_files = {}

    for _, file in ipairs(files) do
      local entry_key = make_key(commit.hash, file.filepath)
      local mark_key = make_mark_key(commit.message, file.filepath)
      local flags = self:get_seen_flags(entry_key, mark_key)

      local status = ReviewState.create_status(file.filepath, file.status, file.old_filepath)

      if flags.has_unseen then
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

      if flags.has_seen then
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
      unseen_commits[#unseen_commits + 1] = { commit = commit, files = unseen_files, index = i }
    end

    if #seen_files > 0 then
      seen_commits[#seen_commits + 1] = { commit = commit, files = seen_files, index = i }
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

return Model
