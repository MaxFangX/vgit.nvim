local loop = require('vgit.core.loop')
local git_repo = require('vgit.git.git_repo')
local git_show = require('vgit.git.git_show')
local git_branch = require('vgit.git.git_branch')
local jj = require('vgit.git.jj')
local record_keys = require('vgit.features.screens.record_keys')
local ReviewState = require('vgit.features.screens.ReviewState')
local ReviewModel = require('vgit.features.screens.ReviewModel')

--[[
  By-commit review model. Each entry is a (commit, file) pair diffed
  against the commit's parent. Contents (parent and commit versions per pair)
  are preloaded via one batched `git cat-file`; all diffs derive from those
  in-process.

  KEYING

  entry_key = commit_hash:filepath   (content/diff caching; hash-exact)
  record_key  = subject_hash:filepath  (index storage; rebase-stable)

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

local function make_record_key(commit_subject, filepath)
  return record_keys.join(record_keys.subject_key(commit_subject), filepath)
end

-- Session-wide contents cache, reused across screen instances so re-entering
-- a review skips the preload. Entry keys embed the commit hash, so cached
-- contents never go stale. Scoped to one review (repo + branch) at a time
-- to bound memory.
local session_contents = { id = nil, contents = {} }

local Model = ReviewModel:extend()

function Model:constructor(opts)
  local base = ReviewModel.constructor(self, opts)
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
    entry_keys_by_record_key = {},
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

function Model:get_record_key(entry)
  return make_record_key(entry.commit.message, entry.filepath)
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

  -- Resolve the base, branch key and review head (parked mid-stack in jj,
  -- the review runs to the stack tip, not HEAD)
  local target, repo_name = self:resolve_target(reponame, base_branch_arg)
  if not target then return nil, repo_name end
  local base_branch, merge_base = target.base, target.merge_base
  local branch_name = target.branch_key
  self.state.merge_base = merge_base

  local cache_id = string.format('%s|%s', reponame, branch_name or '')
  if session_contents.id ~= cache_id then
    session_contents = { id = cache_id, contents = {} }
  end
  self.state.contents = session_contents.contents

  -- Async fetch if stale — notifies user to reopen if base was updated
  git_branch.fetch_ref_if_stale(reponame, base_branch)

  -- Initialize or restore the index
  self.review_state = ReviewState({
    base_branch = base_branch,
    branch_key = branch_name,
    review_type = self:get_review_type(),
    repo_key = repo_name,
  })
  -- Load persisted state from disk (must be called from coroutine context)
  self.review_state:load_from_disk()

  -- Get commits in the PR range, with their messages and files
  local commits, commits_err = git_branch.review_commits(reponame, merge_base, target.head_hash)
  if commits_err then return nil, commits_err end

  if #commits == 0 then
    return nil, { string.format('Branch is the same as %s', base_branch) }
  end

  self.state.commits = commits
  for _, commit in ipairs(commits) do
    self.state.commit_messages[commit.hash] = commit.body
    self.state.commit_files[commit.hash] = commit.files
  end

  -- In a jj repo, the list shows jj change ids instead of git short hashes
  jj.attach_change_ids(reponame, commits)

  -- Marks stored under a reworded subject, or made while reviewing another
  -- branch, are found by jj change id (see record_keys)
  local items = record_keys.items(commits, self.state.commit_files)
  if #items > 0 then self.review_state:reconcile_change_ids(items) end

  -- Preload parent and commit contents in parallel
  local preload_err = self:preload_contents_parallel(commits)
  if preload_err then return nil, preload_err end

  self:rebuild_entries()
  return self.state.entries
end

-- Preload all contents in one `git cat-file --batch` process (2 objects per
-- commit-file: parent + commit). A missing object means the file doesn't
-- exist at that revision (added / deleted side, or the parent of a root
-- commit). Returns an error if git fails, caching nothing.
function Model:preload_contents_parallel(commits)
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

  local specs = {}
  for _, job in ipairs(jobs) do
    specs[#specs + 1] = string.format('%s^:%s', job.commit_hash, job.old_filepath or job.filepath)
    specs[#specs + 1] = make_key(job.commit_hash, job.filepath)
  end

  local results, err = git_show.lines_batch(self.state.reponame, specs)
  if err then return err end

  for i, job in ipairs(jobs) do
    local base = results[(i - 1) * 2 + 1]
    local current = results[(i - 1) * 2 + 2]

    self:set_contents(job.cache_key, {
      base = base.lines or {},
      current = current.lines or {},
      current_deleted = current.missing == true,
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
      local record_key = make_record_key(commit.message, file.filepath)
      local flags = self:get_seen_flags(entry_key, record_key)

      local status = ReviewModel.create_status(file.filepath, file.status, file.old_filepath)

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
