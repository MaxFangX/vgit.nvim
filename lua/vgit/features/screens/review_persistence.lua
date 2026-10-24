local fs = require('vgit.core.fs')

--[[
  review_persistence owns review state on disk: one JSON state file per
  (repo, branch, review type), with each approved snapshot stored once as a
  content-addressed object under the branch:

    $XDG_STATE_HOME/vgit/<repo>/<branch>/<type>.json
    $XDG_STATE_HOME/vgit/<repo>/<branch>/objects/<sha256>

  with / in branch keys encoded as --. Sessions on different vgit versions
  share these files, so the format only grows compatibly (see the v1 pin in
  the spec). Everything here uses only libuv, io and vim.json, except where
  noted, so it is safe in fast event contexts.
]]

local review_persistence = {}

local CURRENT_VERSION = 1
local MAX_BRANCHES = 128

-- Both review types share the branch's object store, so sweeping must honor
-- references from each.
local REVIEW_TYPES = { 'by_file', 'by_commit' }

-- $<var>, else ~/<default>. Reads env vars, as vim.fn.expand isn't
-- fast-event safe.
local function xdg_dir(var, default)
  local dir = os.getenv(var)
  if dir and dir ~= '' then return dir end
  return (os.getenv('HOME') or vim.loop.os_homedir()) .. '/' .. default
end

local function encode_branch(name)
  return (name:gsub('/', '--'))
end

-- Iterates (name, type) over the entries of `dir`; nothing if it can't be read
local function each_dir_entry(dir)
  local handle = vim.loop.fs_scandir(dir)
  return function()
    if handle then return vim.loop.fs_scandir_next(handle) end
  end
end

-- mkdir -p. Returns nil, err on failure.
local function ensure_dir(dir)
  if vim.loop.fs_stat(dir) then return end
  local parent = dir:match('^(.+)/[^/]+$')
  if parent then
    local _, err = ensure_dir(parent)
    if err then return nil, err end
  end

  local ok, mkdir_err, err_name = vim.loop.fs_mkdir(dir, 493)
  if not ok and err_name ~= 'EEXIST' then
    return nil, { string.format('Failed to create %s: %s', dir, mkdir_err) }
  end
end

-- Write `content` to `path` byte for byte, through a temp file of this
-- process, so readers never see a partial file. The temp file is renamed
-- over `path`, or with `exclusive`, linked to it only if `path` doesn't
-- exist yet. Returns nil, err on failure.
local function write_raw_atomic(path, content, exclusive)
  local tmp = string.format('%s.%d.tmp', path, vim.loop.os_getpid())
  local fd, open_err = io.open(tmp, 'wb')
  if not fd then return nil, { open_err } end
  local ok, write_err = fd:write(content)
  local closed, close_err = fd:close()

  local published, publish_err
  if ok and closed then
    if exclusive then
      published, publish_err = vim.loop.fs_link(tmp, path)
    else
      published, publish_err = os.rename(tmp, path)
    end
  end
  os.remove(tmp)
  if not published then return nil, { write_err or close_err or publish_err } end
  return true
end

local function read_raw(path)
  local fd = io.open(path, 'rb')
  if not fd then return nil end
  local content = fd:read('*a')
  fd:close()
  return content
end

--[[
  Migration (added 2026-10-23). Review state used to live in
  $XDG_DATA_HOME/vgit/<repo>/<branch>/<type>_indexed.json and objects/,
  where sessions still running older vgit read, write and sweep it: their
  sweeps delete objects only newer state references, and their classic
  screens overwrite <type>.json in another format. So state moved to its own
  tree, which old code never touches, and each repo's reviews are copied
  over once: the first time a session accesses a repo whose new state dir
  has no MIGRATED_MARKER, every <type>_indexed.json in the index format
  (version 1, with entries) whose review has no state file in the new tree
  yet is copied there, keeping its mtime (eviction's last-used order), after
  hard-linking (or copying) every object it references into the new
  objects/. A referenced object already gone from the old tree just loads as
  missing. The marker is written last, so an interrupted migration retries.

  The copy is one-time, and the old tree is never written: old sessions own
  it. From then on the trees are independent, so marks an old session makes
  later stay in the old tree, and reviews evicted from the new tree stay
  gone. To remove this, delete this block and its call in get_state_dir, and
  optionally the old tree and the markers.
]]

-- In a repo's new state dir, once its old-tree reviews are copied over. A
-- file, so the branch-dir walks skip it.
local MIGRATED_MARKER = '.migrated'

-- Repo state dirs checked this session
local migrated = {}

-- Hard-link, else copy, the object `hash` from objects dir `from` into `to`,
-- unless `to` has it or `from` doesn't
local function link_object(from, to, hash)
  local source, target = from .. '/' .. hash, to .. '/' .. hash
  if vim.loop.fs_stat(target) or not vim.loop.fs_stat(source) then return end
  if vim.loop.fs_link(source, target) then return end

  local content = read_raw(source)
  if content then write_raw_atomic(target, content) end
end

-- Copy the old tree's `<type>_indexed.json` at `old_path` to `new_path`
-- with its objects (see above), if it is in the index format. Returns false
-- if it should have been copied but wasn't.
local function migrate_review(old_branch_dir, new_branch_dir, old_path, new_path)
  local content = read_raw(old_path)
  local ok, data = pcall(vim.json.decode, content or '')
  if not ok or type(data) ~= 'table' or data.version ~= 1 or type(data.entries) ~= 'table' then return true end

  local old_objects, new_objects = old_branch_dir .. '/objects', new_branch_dir .. '/objects'
  local _, err = ensure_dir(new_objects)
  if err then return false end
  local function link(hash)
    if type(hash) == 'string' then link_object(old_objects, new_objects, hash) end
  end
  for _, entry in pairs(data.entries) do
    if type(entry) == 'table' then
      link(entry.approved)
      link(entry.base)
    end
  end

  -- Last, so the new state file never references an object not yet there.
  -- Exclusive, as another session may have saved this review meanwhile.
  if not write_raw_atomic(new_path, content, true) then return vim.loop.fs_stat(new_path) ~= nil end

  local old_stat = vim.loop.fs_stat(old_path)
  if old_stat then
    local mtime = old_stat.mtime.sec + old_stat.mtime.nsec / 1e9
    vim.loop.fs_utime(new_path, mtime, mtime)
  end
  return true
end

local function migrate_old_tree(repo_key, state_dir)
  if migrated[state_dir] then return end
  migrated[state_dir] = true
  local marker = state_dir .. '/' .. MIGRATED_MARKER
  if vim.loop.fs_stat(marker) then return end

  local old_dir = xdg_dir('XDG_DATA_HOME', '.local/share') .. '/vgit/' .. repo_key
  local complete = true
  for name, entry_type in each_dir_entry(old_dir) do
    if entry_type == 'directory' then
      for _, review_type in ipairs(REVIEW_TYPES) do
        local new_path = string.format('%s/%s/%s.json', state_dir, name, review_type)
        local old_path = string.format('%s/%s/%s_indexed.json', old_dir, name, review_type)
        if not vim.loop.fs_stat(new_path) and vim.loop.fs_stat(old_path) then
          complete = migrate_review(old_dir .. '/' .. name, state_dir .. '/' .. name, old_path, new_path) and complete
        end
      end
    end
  end

  -- Last, so a failed or interrupted migration retries next session
  if complete and not select(2, ensure_dir(state_dir)) then write_raw_atomic(marker, '') end
end

-- The state directory of a repo. Every path into a repo's state comes
-- through here, so this runs the migration before anything reads it.
local function get_state_dir(repo_key)
  local state_dir = xdg_dir('XDG_STATE_HOME', '.local/state') .. '/vgit/' .. repo_key
  migrate_old_tree(repo_key, state_dir)
  return state_dir
end

function review_persistence.get_state_path(repo_key, branch_key, review_type)
  return string.format('%s/%s/%s.json', get_state_dir(repo_key), encode_branch(branch_key), review_type)
end

local function get_objects_dir(repo_key, branch_key)
  return string.format('%s/%s/objects', get_state_dir(repo_key), encode_branch(branch_key))
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
  for key, entry in pairs(data.entries) do
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
  if type(data.entries) ~= 'table' then return nil, { string.format('No review entries in %s', path) } end
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
    local state_file, err = review_persistence.load(repo_key, branch_key, review_type)
    if err then return nil end
    for _, ref in pairs(state_file and state_file.records or {}) do
      referenced[ref.hash] = true
      if ref.base_hash then referenced[ref.base_hash] = true end
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
