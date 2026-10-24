local fs = require('vgit.core.fs')

--[[
  review_persistence owns review state on disk: one JSON state file per
  (repo, branch, review type), with each approved snapshot stored once as a
  content-addressed object under the branch:

    $XDG_DATA_HOME/vgit/<repo>/<branch>/<type>.json
    $XDG_DATA_HOME/vgit/<repo>/<branch>/objects/<sha256>

  with / in branch keys encoded as --. Sessions on different vgit versions
  share these files, so the format only grows compatibly (see the v1 pin in
  the spec). Every read here uses only libuv, io and vim.json, so it is safe
  in fast event contexts.
]]

local review_persistence = {}

local CURRENT_VERSION = 1
local MAX_BRANCHES = 128

-- Both review types share the branch's object store, so sweeping must honor
-- references from each.
local REVIEW_TYPES = { 'by_file', 'by_commit' }

-- Prefers env vars over vim.fn.expand, which isn't fast-event safe
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

local function encode_branch(name)
  return (name:gsub('/', '--'))
end

-- Migration (added 2026-10-23): review state moved from <type>_indexed.json
-- to <type>.json, replacing any file there in the old marks format, which
-- has no `entries`. Sessions still running pre-rename code sweep objects by
-- the _indexed file's references alone, so removing it would let them
-- delete that review's snapshots. Thus it is copied, not moved. Such a
-- session can also keep writing the _indexed file, so it is copied again
-- whenever it is newer. Uses libuv and io only, so it is safe in fast event
-- contexts.
-- Delete this block, its call in get_state_dir, and the _indexed refs in
-- referenced_hashes once no session runs pre-rename code; delete leftover
-- _indexed files then too.

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

-- The state directory of a repo. Every path into a repo's state comes
-- through here, so this runs the name migration before anything reads it.
local function get_state_dir(repo_key)
  local state_dir = get_data_home() .. '/vgit/' .. repo_key
  migrate_indexed_names(state_dir)
  return state_dir
end

function review_persistence.get_state_path(repo_key, branch_key, review_type)
  return string.format('%s/%s/%s.json', get_state_dir(repo_key), encode_branch(branch_key), review_type)
end

local function get_objects_dir(repo_key, branch_key)
  return string.format('%s/%s/objects', get_state_dir(repo_key), encode_branch(branch_key))
end

-- Iterates (name, type) over the entries of `dir`; nothing if it can't be read
local function each_dir_entry(dir)
  local handle = vim.loop.fs_scandir(dir)
  return function()
    if handle then return vim.loop.fs_scandir_next(handle) end
  end
end

-- Returns nil, err on failure
local function ensure_dir(dir)
  if vim.fn.mkdir(dir, 'p') == 0 and vim.fn.isdirectory(dir) == 0 then
    return nil, { string.format('Failed to create %s', dir) }
  end
end

-- Identifies one version of a file: a rewrite creates a new inode, so this
-- tells apart even writes within one mtime tick.
local function stamp(stat)
  return string.format('%d.%d:%d', stat.mtime.sec, stat.mtime.nsec, stat.ino)
end

-- The stamp of a review's state file, or nil if it has none. Compared to tell
-- whether another session wrote it.
function review_persistence.state_stamp(repo_key, branch_key, review_type)
  local stat = vim.loop.fs_stat(review_persistence.get_state_path(repo_key, branch_key, review_type))
  return stat and stamp(stat)
end

--[[
  A state file decodes to

    { branch_key, records = { [record_key] = ref }, removed = { [record_key] = change_id } }

  where a ref { hash, base_hash, deleted, change_id } names a record's
  objects (see read_record), and `removed` holds tombstones: keys whose
  record was removed, so it isn't adopted from another branch again. On
  disk, each is an entry of `entries`: { approved, base, deleted, change_id }
  for a record, { change_id } for a tombstone.
]]
local function decode(data)
  local state_file = { branch_key = data.branchName, records = {}, removed = {} }
  -- A file in the old marks format has no entries
  local entries = type(data.entries) == 'table' and data.entries or {}
  for key, entry in pairs(entries) do
    if type(entry) == 'table' and type(entry.approved) == 'string' then
      state_file.records[key] = {
        hash = entry.approved,
        base_hash = entry.base,
        deleted = entry.deleted == true,
        change_id = entry.change_id,
      }
    elseif type(entry) == 'table' and entry.change_id then
      state_file.removed[key] = entry.change_id
    end
  end
  return state_file
end

-- The decoded state file at `path` (see decode), or nil if there is none.
-- Returns nil, err when it can't be used: `err.newer` marks a file from a
-- newer vgit, and `err.unreadable` an I/O failure rather than bad content.
local function read_state_file(path)
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
  return decode(data)
end

-- A review's decoded state file; see read_state_file
function review_persistence.load(repo_key, branch_key, review_type)
  return read_state_file(review_persistence.get_state_path(repo_key, branch_key, review_type))
end

-- Decoded state files by path, with the stamp they were read at, so walking
-- every branch re-reads only the files that changed since
local state_file_cache = {}

-- Iterates (state_file, mtime) over every branch's usable state file of
-- `review_type`, mtime in fractional seconds. The decoded files are shared
-- with later walks, so callers must not modify them.
function review_persistence.each_branch_state(repo_key, review_type)
  local state_dir = get_state_dir(repo_key)
  local next_entry = each_dir_entry(state_dir)
  return function()
    for name, entry_type in next_entry do
      local path = string.format('%s/%s/%s.json', state_dir, name, review_type)
      local stat = entry_type == 'directory' and vim.loop.fs_stat(path)
      if stat then
        local cached = state_file_cache[path]
        if not cached or cached.stamp ~= stamp(stat) then
          cached = { stamp = stamp(stat), state_file = read_state_file(path) }
          state_file_cache[path] = cached
        end
        if cached.state_file and cached.state_file.branch_key then
          return cached.state_file, stat.mtime.sec + stat.mtime.nsec / 1e9
        end
      end
    end
  end
end

-- Content hash used to address snapshot objects. Requires main-loop context
-- (vim.fn).
--
-- nvim converts a Lua string containing NULs (e.g. a binary snapshot) to a
-- Blob at the vim.fn boundary, which sha256() rejects (E976). So NUL bytes
-- are escaped first, as \1 -> \1\1 and \0 -> \1\2. The escape is injective,
-- so distinct contents still hash distinctly.
function review_persistence.hash_lines(lines)
  local content = table.concat(lines, '\n')
  -- Most content has neither byte, and scanning for them is far cheaper than
  -- the escape's two copies
  if content:find('\0', 1, true) or content:find('\1', 1, true) then
    content = content:gsub('\1', '\1\1'):gsub('%z', '\1\2')
  end
  return vim.fn.sha256(content)
end

-- Read a snapshot's lines by hash, or nil if the object is missing.
-- fs.read_file (vim.fn.readfile) rewrites NUL bytes, which would corrupt
-- binary snapshots, so this reads raw bytes, mirroring fs.write_file's format
-- (each line followed by '\n').
function review_persistence.read_object(repo_key, branch_key, hash)
  local fd = io.open(get_objects_dir(repo_key, branch_key) .. '/' .. hash, 'rb')
  if not fd then return nil end
  local content = fd:read('*a')
  fd:close()

  if content == '' then return {} end
  if content:sub(-1) == '\n' then content = content:sub(1, -2) end
  return vim.split(content, '\n', { plain = true })
end

-- The record a ref (see decode) names in `branch_key`'s object store:
-- { lines, deleted, base_lines, hash, base_hash }, or nil if an object is
-- missing.
function review_persistence.read_record(repo_key, branch_key, ref)
  local lines = review_persistence.read_object(repo_key, branch_key, ref.hash)
  local base_lines = ref.base_hash and review_persistence.read_object(repo_key, branch_key, ref.base_hash)
  if not lines or not base_lines then return nil end

  -- The hashes ride along so saves don't rehash unchanged records
  return { lines = lines, deleted = ref.deleted, base_lines = base_lines, hash = ref.hash, base_hash = ref.base_hash }
end

-- Write the objects of `records` (a map of records), caching each record's
-- hashes on it. Records are never modified once set, so the hashes stay
-- valid. Objects are content-addressed and written atomically, so an
-- existing one is complete and is left alone. Stops at the first failure,
-- returning nil, err.
function review_persistence.write_records(repo_key, branch_key, records)
  local dir = get_objects_dir(repo_key, branch_key)
  local _, err = ensure_dir(dir)
  if err then return nil, err end

  local function write_object(hash, lines)
    local path = dir .. '/' .. hash
    if fs.exists(path) then return end
    return fs.write_file_atomic(path, lines)
  end

  for _, record in pairs(records) do
    record.hash = record.hash or review_persistence.hash_lines(record.lines)
    record.base_hash = record.base_hash or review_persistence.hash_lines(record.base_lines)
    _, err = write_object(record.hash, record.lines)
    if not err then _, err = write_object(record.base_hash, record.base_lines) end
    if err then return nil, err end
  end
end

-- Save a review's state file: `records` (written by write_records), with
-- their `change_ids`, and the tombstones of `removed` (a set). Tombstones only
-- matter for adoption, which goes by change id, so those without one are
-- dropped. Does not evict (see evict_lru). Returns the written file's stamp
-- (see state_stamp), or nil, err on failure.
function review_persistence.save(repo_key, branch_key, review_type, records, change_ids, removed)
  local entries = {}
  for key, record in pairs(records) do
    entries[key] = {
      approved = record.hash,
      base = record.base_hash,
      deleted = record.deleted or nil,
      change_id = change_ids[key],
    }
  end
  for key in pairs(removed) do
    if change_ids[key] then entries[key] = { change_id = change_ids[key] } end
  end

  local path = review_persistence.get_state_path(repo_key, branch_key, review_type)
  local _, err = ensure_dir(fs.dirname(path))
  if err then return nil, err end

  -- lastUsed is for older vgit versions, and this one orders branches by mtime
  local data = { version = CURRENT_VERSION, lastUsed = os.time(), branchName = branch_key, entries = entries }
  local stat
  stat, err = fs.write_file_atomic(path, { vim.fn.json_encode(data) })
  if err then return nil, err end
  return stamp(stat)
end

-- Collect object hashes referenced by a branch's state files, or nil if one
-- can't be read (its references are unknown).
local function referenced_hashes(repo_key, branch_key)
  local referenced = {}
  for _, review_type in ipairs(REVIEW_TYPES) do
    -- Migration: a pre-rename session may have written approvals to the
    -- _indexed file since this session copied it to <type>.json.
    for _, name in ipairs({ review_type, review_type .. '_indexed' }) do
      local state_file, err = review_persistence.load(repo_key, branch_key, name)
      if err then return nil end
      for _, ref in pairs(state_file and state_file.records or {}) do
        referenced[ref.hash] = true
        if ref.base_hash then referenced[ref.base_hash] = true end
      end
    end
  end
  return referenced
end

-- Delete objects no longer referenced by either review type.
-- Call after saving state so the JSON files reflect current references.
function review_persistence.sweep_objects(repo_key, branch_key)
  local dir = get_objects_dir(repo_key, branch_key)
  local referenced = vim.loop.fs_stat(dir) and referenced_hashes(repo_key, branch_key)
  if not referenced then return end

  for name, entry_type in each_dir_entry(dir) do
    if entry_type == 'file' and not referenced[name] then fs.remove_file(dir .. '/' .. name) end
  end
end

-- Mtime (seconds) of the newest state file directly in `dir`, or nil if it
-- holds none. save() writes lastUsed along with the file, so mtime orders
-- branches as lastUsed would, without parsing JSON.
local function newest_state_mtime(dir)
  local newest
  for name, entry_type in each_dir_entry(dir) do
    if entry_type == 'file' and name:match('%.json$') then
      local stat = vim.loop.fs_stat(dir .. '/' .. name)
      if stat and (not newest or stat.mtime.sec > newest) then newest = stat.mtime.sec end
    end
  end
  return newest
end

-- List branch dirs holding state, sorted by last use, oldest first. Branch
-- dirs with no state files left are pruned on the way (rmdir only succeeds
-- when empty, so an objects/ dir or stray file keeps the dir).
local function list_branches(state_dir)
  local branches = {}
  for name, entry_type in each_dir_entry(state_dir) do
    if entry_type == 'directory' then
      local dir = state_dir .. '/' .. name
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
-- Called only from the final save, after which the current branch sorts
-- newest, so it is never evicted.
function review_persistence.evict_lru(repo_key)
  local branches = list_branches(get_state_dir(repo_key))
  for i = 1, #branches - MAX_BRANCHES do
    vim.fn.delete(branches[i].dir, 'rf')
  end
end

return review_persistence
