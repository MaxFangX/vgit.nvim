local fs = require('vgit.core.fs')
local persistence = require('vgit.features.screens.ReviewPersistence')

local eq = assert.are.same

-- Write a by-commit review file whose approved entries reference `subjects`
-- (entry keys are `subject_hash:filepath`).
local function write_review(root, branch_name, subjects, last_used)
  local entries = {}
  for _, subject in ipairs(subjects) do
    entries[subject .. ':file.txt'] = { approved = 'hash' }
  end
  local dir = root .. '/vgit/repo/' .. branch_name:gsub('/', '--')
  vim.fn.mkdir(dir, 'p')
  local data = { version = 1, lastUsed = last_used, branchName = branch_name, entries = entries }
  vim.fn.writefile({ vim.fn.json_encode(data) }, dir .. '/by_commit.json')
end

describe('ReviewPersistence snapshot objects:', function()
  local root, saved_xdg

  before_each(function()
    saved_xdg = vim.env.XDG_DATA_HOME
    root = vim.fn.tempname()
    vim.env.XDG_DATA_HOME = root
  end)

  after_each(function()
    vim.env.XDG_DATA_HOME = saved_xdg
    vim.fn.delete(root, 'rf')
  end)

  it('hashes binary content without tripping the vim.fn Blob conversion', function()
    -- A NUL byte in the concatenated content converts the string to a Blob at
    -- the vim.fn boundary, and sha256() rejects Blobs (E976). Hit in the wild
    -- by an .age secret inside a commit review.
    local hash = persistence.hash_lines({ 'age-encryption.org/v1', '\0\1binary\0' })
    eq(#hash, 64)

    -- The NUL escape must not collide distinct contents.
    assert.are_not.same(persistence.hash_lines({ '\0' }), persistence.hash_lines({ '\1\2' }))
  end)

  it('round-trips binary snapshot lines through the object store', function()
    local lines = { 'text line', '\0nul\0inside', '', 'trailing' }
    local hash = persistence.hash_lines(lines)
    persistence.write_objects('repo', 'feature', { [hash] = lines })

    eq(persistence.read_object('repo', 'feature', hash), lines)
    eq(persistence.read_object('repo', 'feature', 'missing-hash'), nil)
  end)
end)

describe('ReviewPersistence.branch_by_subjects:', function()
  local root, saved_xdg

  before_each(function()
    saved_xdg = vim.env.XDG_DATA_HOME
    root = vim.fn.tempname()
    vim.env.XDG_DATA_HOME = root
  end)

  after_each(function()
    vim.env.XDG_DATA_HOME = saved_xdg
    vim.fn.delete(root, 'rf')
  end)

  it('picks the review with the most overlap with HEAD subjects', function()
    write_review(root, 'feature', { 's1', 's2', 's3' }, 100)
    write_review(root, 'other', { 's3', 'x9' }, 200)

    -- feature shares s1,s2,s3 (3); other shares only s3 (1).
    eq(persistence.branch_by_subjects('repo', { s1 = true, s2 = true, s3 = true }), 'feature')
  end)

  it('breaks equal overlap toward the most recently used review', function()
    write_review(root, 'older', { 's1', 's2' }, 100)
    write_review(root, 'newer', { 's1', 's2' }, 200)

    eq(persistence.branch_by_subjects('repo', { s1 = true, s2 = true }), 'newer')
  end)

  it('returns nil when overlap is below the threshold (coincidental)', function()
    write_review(root, 'feature', { 's1', 's2', 's3' }, 100)

    -- Only one shared subject — not enough to claim HEAD.
    eq(persistence.branch_by_subjects('repo', { s1 = true, z = true }), nil)
  end)

  it('returns nil when no review exists for the repo', function()
    eq(persistence.branch_by_subjects('repo', { s1 = true, s2 = true }), nil)
  end)
end)

describe('ReviewPersistence.evict_lru:', function()
  local root, saved_xdg

  before_each(function()
    saved_xdg = vim.env.XDG_DATA_HOME
    root = vim.fn.tempname()
    vim.env.XDG_DATA_HOME = root
  end)

  after_each(function()
    vim.env.XDG_DATA_HOME = saved_xdg
    vim.fn.delete(root, 'rf')
  end)

  -- Create a branch dir holding a state file with the given mtime (seconds).
  local function write_branch(name, mtime)
    local dir = root .. '/vgit/repo/' .. name
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/by_commit.json'
    vim.fn.writefile({ '{}' }, path)
    vim.loop.fs_utime(path, mtime, mtime)
    return dir
  end

  it('removes the least recently used branches beyond the cap', function()
    local dirs = {}
    for i = 1, 130 do
      dirs[i] = write_branch('b' .. i, 1000 + i)
    end

    persistence.evict_lru('repo')

    eq(vim.fn.isdirectory(dirs[1]), 0)
    eq(vim.fn.isdirectory(dirs[2]), 0)
    eq(vim.fn.isdirectory(dirs[3]), 1)
    eq(vim.fn.isdirectory(dirs[130]), 1)
  end)

  it('orders a branch by its newest state file', function()
    local old = write_branch('old', 1000)
    local mixed = write_branch('mixed', 500)
    local newer = mixed .. '/by_file.json'
    vim.fn.writefile({ '{}' }, newer)
    vim.loop.fs_utime(newer, 2000, 2000)
    for i = 1, 127 do
      write_branch('b' .. i, 3000 + i)
    end

    persistence.evict_lru('repo')

    eq(vim.fn.isdirectory(old), 0)
    eq(vim.fn.isdirectory(mixed), 1)
  end)

  it('prunes empty branch dirs but keeps ones with other content', function()
    local empty = root .. '/vgit/repo/empty'
    local objects_only = root .. '/vgit/repo/objects-only/objects'
    vim.fn.mkdir(empty, 'p')
    vim.fn.mkdir(objects_only, 'p')
    write_branch('live', 1000)

    persistence.evict_lru('repo')

    eq(vim.fn.isdirectory(empty), 0)
    eq(vim.fn.isdirectory(objects_only), 1)
  end)

  it('is a no-op when the repo has no state dir', function()
    persistence.evict_lru('repo')
  end)
end)

describe('ReviewPersistence name migration:', function()
  local root, saved_xdg, dir

  before_each(function()
    saved_xdg = vim.env.XDG_DATA_HOME
    root = vim.fn.tempname()
    -- A fresh data home per spec, so the per-state-dir memo never carries over
    vim.env.XDG_DATA_HOME = root
    dir = root .. '/vgit/repo/feature'
    vim.fn.mkdir(dir, 'p')
  end)

  after_each(function()
    vim.env.XDG_DATA_HOME = saved_xdg
    vim.fn.delete(root, 'rf')
  end)

  -- Write a state file under the branch dir with the given contents and
  -- mtime (seconds).
  local function write_state(name, data, mtime)
    local path = dir .. '/' .. name
    vim.fn.writefile({ vim.fn.json_encode(vim.tbl_extend('force', { version = 1, branchName = 'feature' }, data)) }, path)
    vim.loop.fs_utime(path, mtime, mtime)
  end

  local function approved(entries_key, hash)
    return { entries = { [entries_key] = { approved = hash } } }
  end

  local function read(name)
    local fd = assert(io.open(dir .. '/' .. name, 'rb'))
    local content = fd:read('*a')
    fd:close()
    return content
  end

  local function exists(name)
    return vim.loop.fs_stat(dir .. '/' .. name) ~= nil
  end

  local function load_entries(review_type)
    return persistence.load('repo', 'feature', review_type).entries
  end

  it('copies an _indexed file when no state file exists, keeping the original', function()
    write_state('by_commit_indexed.json', approved('s:a.lua', 'old'), 1000)

    eq(load_entries('by_commit'), { ['s:a.lua'] = { approved = 'old' } })
    eq(read('by_commit.json'), read('by_commit_indexed.json'))
  end)

  it('replaces a classic-format file, even a newer one', function()
    write_state('by_file.json', { marks = { ['a.lua:cid'] = true } }, 2000)
    write_state('by_file_indexed.json', approved('a.lua', 'old'), 1000)

    local data = persistence.load('repo', 'feature', 'by_file')
    eq(data.entries, { ['a.lua'] = { approved = 'old' } })
    eq(data.marks, nil)
    eq(exists('by_file_indexed.json'), true)
  end)

  it('replaces an older new-format file', function()
    write_state('by_commit.json', approved('s:a.lua', 'new'), 1000)
    write_state('by_commit_indexed.json', approved('s:a.lua', 'old'), 2000)

    eq(load_entries('by_commit'), { ['s:a.lua'] = { approved = 'old' } })
  end)

  it('keeps a new-format file that is newer or equally new', function()
    write_state('by_commit.json', approved('s:a.lua', 'new'), 2000)
    write_state('by_commit_indexed.json', approved('s:a.lua', 'old'), 1000)
    write_state('by_file.json', approved('a.lua', 'new'), 1000)
    write_state('by_file_indexed.json', approved('a.lua', 'old'), 1000)

    eq(load_entries('by_commit'), { ['s:a.lua'] = { approved = 'new' } })
    eq(load_entries('by_file'), { ['a.lua'] = { approved = 'new' } })
    eq(exists('by_commit_indexed.json'), true)
  end)

  it('writes the copy atomically through a temp file', function()
    local writes = {}
    local write_file_atomic = fs.write_file_atomic
    fs.write_file_atomic = function(path, lines)
      writes[#writes + 1] = path
      return write_file_atomic(path, lines)
    end
    write_state('by_commit_indexed.json', approved('s:a.lua', 'old'), 1000)

    local ok, err = pcall(load_entries, 'by_commit')
    fs.write_file_atomic = write_file_atomic
    assert(ok, err)
    eq(writes, { dir .. '/by_commit.json' })
    eq(exists('by_commit.json.tmp'), false)
  end)

  it('copies again once a pre-rename session rewrites the _indexed file', function()
    write_state('by_commit_indexed.json', approved('s:a.lua', 'first'), 1000)
    eq(load_entries('by_commit'), { ['s:a.lua'] = { approved = 'first' } })

    -- An old-code session saves after the copy; a later session (fresh
    -- memo, here a fresh module) picks the newer _indexed file up.
    write_state('by_commit_indexed.json', approved('s:a.lua', 'second'), os.time() + 60)
    package.loaded['vgit.features.screens.ReviewPersistence'] = nil
    local ok, fresh = pcall(require, 'vgit.features.screens.ReviewPersistence')
    package.loaded['vgit.features.screens.ReviewPersistence'] = persistence
    assert(ok, fresh)
    eq(fresh.load('repo', 'feature', 'by_commit').entries, { ['s:a.lua'] = { approved = 'second' } })
  end)

  it('runs from the branch resolver too', function()
    write_state('by_commit_indexed.json', { lastUsed = 100, entries = { ['s1:a.lua'] = { approved = 'h' } } }, 1000)

    eq(persistence.branch_by_subjects('repo', { s1 = true }), 'feature')
    eq(read('by_commit.json'), read('by_commit_indexed.json'))
  end)

  it('runs at most once per session', function()
    write_state('by_commit_indexed.json', approved('s:a.lua', 'first'), 1000)
    load_entries('by_commit')

    write_state('by_commit_indexed.json', approved('s:a.lua', 'second'), os.time() + 60)
    eq(load_entries('by_commit'), { ['s:a.lua'] = { approved = 'first' } })
  end)

  it('keeps objects referenced only by an _indexed file when sweeping', function()
    -- A pre-rename session approved more after this session made its copy
    write_state('by_file.json', approved('a.lua', 'shared'), 2000)
    load_entries('by_file')
    write_state('by_file_indexed.json', { entries = { ['a.lua'] = { approved = 'shared' }, ['b.lua'] = { approved = 'later' } } }, 3000)
    persistence.write_objects('repo', 'feature', { shared = { 's' }, later = { 'l' }, stale = { 'x' } })

    persistence.sweep_objects('repo', 'feature')
    eq(persistence.read_object('repo', 'feature', 'shared'), { 's' })
    eq(persistence.read_object('repo', 'feature', 'later'), { 'l' })
    eq(persistence.read_object('repo', 'feature', 'stale'), nil)
  end)
end)
