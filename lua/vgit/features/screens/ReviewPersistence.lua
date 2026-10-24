local fs = require('vgit.core.fs')

--[[
  ReviewPersistence handles disk I/O for review state.

  Storage location: $XDG_DATA_HOME/vgit/<repo>/<branch>/<type>.json
  (default: ~/.local/share/vgit/<repo>/<branch>/<type>.json)

  Branch names with / are encoded as -- (e.g., feature/foo -> feature--foo)

  Approved file snapshots are stored content-addressed, one file per unique
  content, under the branch's state directory:

    $XDG_DATA_HOME/vgit/<repo>/<branch>/objects/<sha256>

  The by_file.json / by_commit.json files reference objects by hash;
  content addressing dedupes identical approved contents (e.g. the same
  lockfile approved in several commits). Objects are swept on save.

  Features:
    - LRU eviction: max 128 branches per repository (all review types for a
      branch count as one), run from the quit-time save via evict_lru; it
      removes the whole branch directory, objects included
    - Automatic lastUsed timestamp updates
]]

local ReviewPersistence = {}

local CURRENT_VERSION = 1
local MAX_BRANCHES = 128

-- Both review types share the branch's object store; sweeping must honor
-- references from each.
local REVIEW_TYPES = { 'by_file', 'by_commit' }

-- Get XDG data home directory. Prefers env vars (safe in fast event contexts)
-- over vim.fn.expand, since branch_by_subjects below may run from the branch
-- resolver.
local function get_data_home()
  local xdg = os.getenv('XDG_DATA_HOME')
  if xdg and xdg ~= '' then
    return xdg
  end
  local home = os.getenv('HOME')
  if home and home ~= '' then
    return home .. '/.local/share'
  end
  return vim.fn.expand('~/.local/share')
end

-- Encode branch name for filesystem (/ -> --)
local function encode_branch(name)
  return name:gsub('/', '--')
end

-- Migration (added 2026-10-23): review state moved from <type>_indexed.json
-- to <type>.json, replacing any file there in the retired classic format.
-- The _indexed file is copied, not moved: sessions still running pre-rename
-- code sweep objects by its references alone, so removing it would let them
-- delete the snapshots of that review. Such a session can also keep writing
-- the _indexed file, so it is copied again whenever it is newer. libuv/io
-- only (safe in fast event contexts). Delete this block, its call in
-- get_state_dir, and the _indexed refs in referenced_hashes once no session
-- runs pre-rename code; delete leftover _indexed files then too.

-- Whether stat result `a` has a newer mtime than `b`
local function is_newer(a, b)
  if a.mtime.sec ~= b.mtime.sec then return a.mtime.sec > b.mtime.sec end
  return a.mtime.nsec > b.mtime.nsec
end

-- Whether the state file at `path` is in the current format (has entries)
local function has_entries(path)
  local fd = io.open(path, 'r')
  if not fd then return false end
  local content = fd:read('*a')
  fd:close()

  local ok, data = pcall(vim.json.decode, content)
  return ok and type(data) == 'table' and type(data.entries) == 'table'
end

-- Copy `from` over `to` atomically, so a crash can't leave a truncated file
local function copy_file(from, to)
  local fd = io.open(from, 'rb')
  if not fd then return end
  local content = fd:read('*a')
  fd:close()

  -- write_file_atomic terminates each line with '\n'
  if content:sub(-1) == '\n' then content = content:sub(1, -2) end
  fs.write_file_atomic(to, { content })
end

-- State dirs already migrated this session
local migrated = {}

-- Copy each branch's <type>_indexed.json over <type>.json unless the latter
-- is already in the new format and at least as new. Once per state dir.
local function migrate_indexed_names(state_dir)
  if migrated[state_dir] then return end
  migrated[state_dir] = true

  local handle = vim.loop.fs_scandir(state_dir)
  if not handle then return end

  while true do
    local entry, entry_type = vim.loop.fs_scandir_next(handle)
    if not entry then break end
    if entry_type == 'directory' then
      for _, review_type in ipairs(REVIEW_TYPES) do
        local path = string.format('%s/%s/%s.json', state_dir, entry, review_type)
        local old_path = string.format('%s/%s/%s_indexed.json', state_dir, entry, review_type)
        local old_stat = vim.loop.fs_stat(old_path)
        local stat = old_stat and vim.loop.fs_stat(path)
        if old_stat and (not stat or is_newer(old_stat, stat) or not has_entries(path)) then
          copy_file(old_path, path)
        end
      end
    end
  end
end

-- Get state directory path for a repo. Every path into a repo's state comes
-- through here, so this runs the name migration before anything reads it.
function ReviewPersistence.get_state_dir(repo_name)
  local state_dir = get_data_home() .. '/vgit/' .. repo_name
  migrate_indexed_names(state_dir)
  return state_dir
end

-- Get state file path for a (repo, branch, review_type) tuple
function ReviewPersistence.get_state_path(repo_name, branch_name, review_type)
  local dir = ReviewPersistence.get_state_dir(repo_name)
  return dir .. '/' .. encode_branch(branch_name) .. '/' .. review_type .. '.json'
end

function ReviewPersistence.get_objects_dir(repo_name, branch_name)
  return string.format('%s/%s/objects', ReviewPersistence.get_state_dir(repo_name), encode_branch(branch_name))
end

-- Ensure state directory exists. Returns nil, err on failure.
local function ensure_dir(dir)
  if vim.fn.mkdir(dir, 'p') == 0 and vim.fn.isdirectory(dir) == 0 then
    return nil, { string.format('Failed to create %s', dir) }
  end
end

-- Mtime (seconds) of the newest state file directly in `dir`, or nil if it
-- holds none. Stat only; save() writes lastUsed and the file at the same
-- instant, so mtime orders branches identically without parsing JSON.
local function newest_state_mtime(dir)
  local handle = vim.loop.fs_scandir(dir)
  if not handle then return nil end

  local newest
  while true do
    local entry, entry_type = vim.loop.fs_scandir_next(handle)
    if not entry then break end
    if entry_type == 'file' and entry:match('%.json$') then
      local stat = vim.loop.fs_stat(dir .. '/' .. entry)
      if stat and (not newest or stat.mtime.sec > newest) then newest = stat.mtime.sec end
    end
  end
  return newest
end

-- List branch dirs holding state, sorted by last use, oldest first. Branch
-- dirs with no state files left are pruned on the way (rmdir only succeeds
-- when empty, so an objects/ dir or stray file keeps the dir).
local function list_branches(state_dir)
  local handle = vim.loop.fs_scandir(state_dir)
  if not handle then return {} end

  local branches = {}
  while true do
    local entry, entry_type = vim.loop.fs_scandir_next(handle)
    if not entry then break end
    if entry_type == 'directory' then
      local dir = state_dir .. '/' .. entry
      local last_used = newest_state_mtime(dir)
      if last_used then
        branches[#branches + 1] = { dir = dir, last_used = last_used }
      else
        vim.loop.fs_rmdir(dir)
      end
    end
  end

  table.sort(branches, function(a, b) return a.last_used < b.last_used end)
  return branches
end

-- Evict least-recently-used branches until the repo is within capacity.
-- Called from the quit-time save (never the write-behind one): the current
-- branch was just saved, so it sorts newest and is never a candidate.
function ReviewPersistence.evict_lru(repo_name)
  local branches = list_branches(ReviewPersistence.get_state_dir(repo_name))
  for i = 1, #branches - MAX_BRANCHES do
    vim.fn.delete(branches[i].dir, 'rf') -- Remove the branch dir and all its state files
  end
end

-- The decoded state file at `path`, or nil if there is none. Returns nil, err
-- when it can't be used: `err.newer` marks a file from a newer vgit, and
-- `err.unreadable` an I/O failure rather than bad content. libuv/io only
-- (safe in fast event contexts).
local function load_path(path)
  local fd, open_err, err_name = vim.loop.fs_open(path, 'r', 438)
  if not fd then
    if err_name == 'ENOENT' then return nil end
    return nil, { string.format('Failed to open %s: %s', path, open_err), unreadable = true }
  end
  local stat = vim.loop.fs_fstat(fd)
  local content = stat and vim.loop.fs_read(fd, stat.size, 0)
  vim.loop.fs_close(fd)
  if not content then return nil, { string.format('Failed to read %s', path), unreadable = true } end

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= 'table' then return nil, { string.format('Failed to parse %s', path) } end
  if type(data.version) == 'number' and data.version > CURRENT_VERSION then
    return nil, { string.format('%s is from a newer vgit (schema version %d)', path, data.version), newer = true }
  end
  if data.version ~= CURRENT_VERSION then
    return nil, { string.format('Unknown schema version %s in %s', tostring(data.version), path) }
  end

  -- A file in the retired classic format has no entries
  if type(data.entries) ~= 'table' then data.entries = {} end
  return data
end

-- Load a state file; see load_path
function ReviewPersistence.load(repo_name, branch_name, review_type)
  return load_path(ReviewPersistence.get_state_path(repo_name, branch_name, review_type))
end

-- Decoded sibling state files by path, each tagged with the file's mtime, so
-- opening a review re-reads only the sibling files that changed since.
local sibling_cache = {}

-- The other branches' readable state files for `review_type`, most recently
-- used first, as `{ branch_name, data }` tables.
function ReviewPersistence.load_siblings(repo_name, branch_name, review_type)
  local state_dir = ReviewPersistence.get_state_dir(repo_name)
  local handle = vim.loop.fs_scandir(state_dir)
  if not handle then return {} end

  local own_dir = encode_branch(branch_name)
  local siblings = {}
  while true do
    local entry, entry_type = vim.loop.fs_scandir_next(handle)
    if not entry then break end
    local path = state_dir .. '/' .. entry .. '/' .. review_type .. '.json'
    local stat = entry_type == 'directory' and entry ~= own_dir and vim.loop.fs_stat(path)
    if stat then
      local mtime = string.format('%d.%d', stat.mtime.sec, stat.mtime.nsec)
      local cached = sibling_cache[path]
      if not cached or cached.mtime ~= mtime then
        cached = { mtime = mtime, data = load_path(path) }
        sibling_cache[path] = cached
      end
      if cached.data and cached.data.branchName then
        siblings[#siblings + 1] = { branch_name = cached.data.branchName, data = cached.data }
      end
    end
  end

  table.sort(siblings, function(a, b) return (a.data.lastUsed or 0) > (b.data.lastUsed or 0) end)
  return siblings
end

-- Save state to disk. Does not evict; see evict_lru. Returns nil, err on
-- failure.
function ReviewPersistence.save(repo_name, branch_name, review_type, state_data)
  local path = ReviewPersistence.get_state_path(repo_name, branch_name, review_type)
  local _, err = ensure_dir(fs.dirname(path))
  if err then return nil, err end

  -- Add metadata
  state_data.version = CURRENT_VERSION
  state_data.lastUsed = os.time()
  state_data.branchName = branch_name

  return fs.write_file_atomic(path, { vim.fn.json_encode(state_data) })
end

-- Content hash used to address snapshot objects. Requires main-loop context
-- (vim.fn); callers already free_textlock around load/save.
-- NUL bytes (binary snapshots, e.g. .age secrets) are escaped first: nvim
-- converts a Lua string containing NULs to a Blob at the vim.fn boundary,
-- which sha256() rejects (E976). The escape (\1 -> \1\1, \0 -> \1\2) is
-- injective, so distinct contents still hash distinctly.
function ReviewPersistence.hash_lines(lines)
  local content = table.concat(lines, '\n'):gsub('\1', '\1\1'):gsub('%z', '\1\2')
  return vim.fn.sha256(content)
end

-- Read a snapshot's lines by hash. Returns nil if missing (e.g. object lost).
-- Raw io rather than fs.read_file (vim.fn.readfile), which silently rewrites
-- NUL bytes and would corrupt binary snapshots on the round-trip; must mirror
-- fs.write_file's raw format (each line followed by '\n').
function ReviewPersistence.read_object(repo_name, branch_name, hash)
  local path = ReviewPersistence.get_objects_dir(repo_name, branch_name) .. '/' .. hash
  local fd = io.open(path, 'rb')
  if not fd then return nil end
  local content = fd:read('*a')
  fd:close()

  if content == '' then return {} end
  if content:sub(-1) == '\n' then content = content:sub(1, -2) end
  return vim.split(content, '\n', { plain = true })
end

-- Write snapshot objects: objects is a map of hash -> lines. Existing objects
-- are left alone (content-addressed, so contents are immutable), which is
-- only safe because writes are atomic: a truncated object would otherwise be
-- kept forever. Stops at the first failure, returning nil, err.
function ReviewPersistence.write_objects(repo_name, branch_name, objects)
  local dir = ReviewPersistence.get_objects_dir(repo_name, branch_name)
  local _, err = ensure_dir(dir)
  if err then return nil, err end

  for hash, lines in pairs(objects) do
    local path = dir .. '/' .. hash
    if not fs.exists(path) then
      _, err = fs.write_file_atomic(path, lines)
      if err then return nil, err end
    end
  end
end

-- Collect object hashes referenced by a branch's state files, or nil if one
-- can't be read (its references are unknown).
local function referenced_hashes(repo_name, branch_name)
  local referenced = {}
  for _, review_type in ipairs(REVIEW_TYPES) do
    -- Migration: a pre-rename session may have written approvals to the
    -- _indexed file since this session copied it to <type>.json.
    for _, name in ipairs({ review_type, review_type .. '_indexed' }) do
      local data, err = ReviewPersistence.load(repo_name, branch_name, name)
      if err then return nil end
      if data then
        for _, entry in pairs(data.entries) do
          if type(entry) == 'table' and entry.approved then
            referenced[entry.approved] = true
            if entry.base then referenced[entry.base] = true end
          end
        end
      end
    end
  end
  return referenced
end

-- Delete objects no longer referenced by either review type.
-- Call after saving state so the JSON files reflect current references.
function ReviewPersistence.sweep_objects(repo_name, branch_name)
  local dir = ReviewPersistence.get_objects_dir(repo_name, branch_name)
  local handle = vim.loop.fs_scandir(dir)
  if not handle then return end

  local referenced = referenced_hashes(repo_name, branch_name)
  if not referenced then return end

  while true do
    local entry, entry_type = vim.loop.fs_scandir_next(handle)
    if not entry then break end
    if entry_type == 'file' and not referenced[entry] then
      fs.remove_file(dir .. '/' .. entry)
    end
  end
end

-- Minimum shared commit-subjects for a stored review to be considered "the review
-- for HEAD" — guards against a coincidental one-commit overlap between branches.
local MIN_SUBJECT_OVERLAP = 2

-- Count how many of a by-commit review's approved entries have a
-- subject hash (the prefix of each entry key) present in head_subjects.
local function subject_overlap(path, head_subjects)
  local fd = io.open(path, 'r')
  if not fd then return 0, nil, 0 end
  local content = fd:read('*a')
  fd:close()

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= 'table' or type(data.entries) ~= 'table' or not data.branchName then
    return 0, nil, 0, 0
  end

  -- Also count the review's distinct stored subjects, so the caller can scale
  -- its overlap threshold to reviews smaller than the absolute minimum.
  local overlap, stored, counted = 0, 0, {}
  for key, entry in pairs(data.entries) do
    if type(entry) == 'table' and entry.approved then
      local subject = key:match('^([^:]+)')
      if subject and not counted[subject] then
        counted[subject] = true
        stored = stored + 1
        if head_subjects[subject] then overlap = overlap + 1 end
      end
    end
  end
  return overlap, data.branchName, data.lastUsed or 0, stored
end

-- Resolve which stored review (branch) best covers HEAD's current commits, keyed on
-- commit subjects (rebase-stable, like the entry keys) so a review is followed across
-- rebases regardless of where the branch bookmark sits. A review qualifies with
-- `MIN_SUBJECT_OVERLAP` matching subjects; below that (a single-commit stack can
-- otherwise never match) it qualifies only if *all* its stored subjects match AND
-- they cover at least half of HEAD's stack — one stray subject (e.g. entries saved
-- under a misresolved key) must not claim a larger stack away from its bookmark.
-- Returns the qualifying branch with the most overlap (ties break toward the most
-- recently used), or nil. Uses libuv/io/vim.json so it's safe in the fast event
-- contexts where the branch resolver runs.
function ReviewPersistence.branch_by_subjects(repo_name, head_subjects)
  local head_count = 0
  for _ in pairs(head_subjects) do
    head_count = head_count + 1
  end
  if head_count == 0 then return nil end

  local state_dir = ReviewPersistence.get_state_dir(repo_name)
  local handle = vim.loop.fs_scandir(state_dir)
  if not handle then return nil end

  local best_name, best_overlap, best_used = nil, 0, 0
  local function consider(overlap, branch_name, last_used, stored)
    local qualifies = overlap >= MIN_SUBJECT_OVERLAP
      or (overlap > 0 and overlap == stored and 2 * overlap >= head_count)
    if qualifies and (overlap > best_overlap or (overlap == best_overlap and last_used > best_used)) then
      best_name, best_overlap, best_used = branch_name, overlap, last_used
    end
  end

  while true do
    local entry, entry_type = vim.loop.fs_scandir_next(handle)
    if not entry then break end
    if entry_type == 'directory' and entry ~= 'objects' then
      consider(subject_overlap(state_dir .. '/' .. entry .. '/by_commit.json', head_subjects))
    end
  end

  return best_name
end

return ReviewPersistence
