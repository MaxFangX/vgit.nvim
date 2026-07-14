local fs = require('vgit.core.fs')
local persistence = require('vgit.features.screens.ReviewStatePersistence')

--[[
  IndexedReviewPersistence adds snapshot storage for the indexed review
  screens on top of ReviewStatePersistence (which still owns the JSON files,
  paths, LRU eviction, and schema versioning).

  Approved file snapshots are stored content-addressed, one file per unique
  content, under the branch's state directory:

    $XDG_DATA_HOME/vgit/<repo>/<branch>/objects/<sha256>

  The by_file_indexed.json / by_commit_indexed.json files reference objects by
  hash; content addressing dedupes identical approved contents (e.g. the same
  lockfile approved in several commits). Objects are swept on save, and the
  whole branch directory (objects included) is removed by LRU eviction.
]]

local IndexedReviewPersistence = {}

-- Both indexed review types share the branch's object store; sweeping must
-- honor references from each.
local INDEXED_REVIEW_TYPES = { 'by_file_indexed', 'by_commit_indexed' }

IndexedReviewPersistence.load = persistence.load
IndexedReviewPersistence.save = persistence.save
IndexedReviewPersistence.delete = persistence.delete
IndexedReviewPersistence.get_state_path = persistence.get_state_path
IndexedReviewPersistence.handle_load_error = persistence.handle_load_error

local function encode_branch(name)
  return name:gsub('/', '--')
end

function IndexedReviewPersistence.get_objects_dir(repo_name, branch_name)
  return string.format('%s/%s/objects', persistence.get_state_dir(repo_name), encode_branch(branch_name))
end

-- Content hash used to address snapshot objects. Requires main-loop context
-- (vim.fn); callers already free_textlock around load/save.
-- NUL bytes (binary snapshots, e.g. .age secrets) are escaped first: nvim
-- converts a Lua string containing NULs to a Blob at the vim.fn boundary,
-- which sha256() rejects (E976). The escape (\1 -> \1\1, \0 -> \1\2) is
-- injective, so distinct contents still hash distinctly.
function IndexedReviewPersistence.hash_lines(lines)
  local content = table.concat(lines, '\n'):gsub('\1', '\1\1'):gsub('%z', '\1\2')
  return vim.fn.sha256(content)
end

-- Read a snapshot's lines by hash. Returns nil if missing (e.g. object lost).
-- Raw io rather than fs.read_file (vim.fn.readfile), which silently rewrites
-- NUL bytes and would corrupt binary snapshots on the round-trip; must mirror
-- fs.write_file's raw format (each line followed by '\n').
function IndexedReviewPersistence.read_object(repo_name, branch_name, hash)
  local path = IndexedReviewPersistence.get_objects_dir(repo_name, branch_name) .. '/' .. hash
  local fd = io.open(path, 'rb')
  if not fd then return nil end
  local content = fd:read('*a')
  fd:close()

  if content == '' then return {} end
  if content:sub(-1) == '\n' then content = content:sub(1, -2) end
  return vim.split(content, '\n', { plain = true })
end

-- Write snapshot objects: objects is a map of hash -> lines. Existing objects
-- are left alone (content-addressed, so contents are immutable).
function IndexedReviewPersistence.write_objects(repo_name, branch_name, objects)
  local dir = IndexedReviewPersistence.get_objects_dir(repo_name, branch_name)
  if not fs.exists(dir) then
    vim.fn.mkdir(dir, 'p')
  end

  for hash, lines in pairs(objects) do
    local path = dir .. '/' .. hash
    if not fs.exists(path) then
      fs.write_file(path, lines)
    end
  end
end

-- Collect object hashes referenced by a branch's indexed state files.
local function referenced_hashes(repo_name, branch_name)
  local referenced = {}
  for _, review_type in ipairs(INDEXED_REVIEW_TYPES) do
    local data = persistence.load(repo_name, branch_name, review_type)
    if data and type(data.entries) == 'table' then
      for _, entry in pairs(data.entries) do
        if type(entry) == 'table' and entry.approved then
          referenced[entry.approved] = true
          if entry.base then referenced[entry.base] = true end
        end
      end
    end
  end
  return referenced
end

-- Delete objects no longer referenced by either indexed review type.
-- Call after saving state so the JSON files reflect current references.
function IndexedReviewPersistence.sweep_objects(repo_name, branch_name)
  local dir = IndexedReviewPersistence.get_objects_dir(repo_name, branch_name)
  local handle = vim.loop.fs_scandir(dir)
  if not handle then return end

  local referenced = referenced_hashes(repo_name, branch_name)
  while true do
    local entry, entry_type = vim.loop.fs_scandir_next(handle)
    if not entry then break end
    if entry_type == 'file' and not referenced[entry] then
      fs.remove_file(dir .. '/' .. entry)
    end
  end
end

-- Count how many of an indexed by-commit review's approved entries have a
-- subject hash (the prefix of each entry key) present in head_subjects.
local function indexed_subject_overlap(path, head_subjects)
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

local MIN_SUBJECT_OVERLAP = 2

-- Resolve which stored review best covers HEAD's commit subjects, like
-- ReviewStatePersistence.branch_by_subjects, but consulting both the classic
-- by_commit marks and the indexed by_commit entries. A review qualifies with
-- `MIN_SUBJECT_OVERLAP` matching subjects; below that it qualifies only if
-- *all* its stored subjects match AND they cover at least half of HEAD's
-- stack (see the classic resolver for rationale). Safe in fast event
-- contexts (libuv/io/vim.json only).
function IndexedReviewPersistence.branch_by_subjects(repo_name, head_subjects)
  local head_count = 0
  for _ in pairs(head_subjects) do
    head_count = head_count + 1
  end
  if head_count == 0 then return nil end

  local state_dir = persistence.get_state_dir(repo_name)
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
      local branch_dir = state_dir .. '/' .. entry
      consider(persistence.subject_overlap(branch_dir .. '/by_commit.json', head_subjects))
      consider(indexed_subject_overlap(branch_dir .. '/by_commit_indexed.json', head_subjects))
    end
  end

  return best_name
end

return IndexedReviewPersistence
