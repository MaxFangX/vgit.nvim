local fs = require('vgit.core.fs')
local persistence = require('vgit.features.screens.ReviewPersistence')
-- Not a module path: plenary runs specs without the repo root on package.path
local review = dofile('tests/helpers/review.lua')

local use_temp_data_home = review.use_temp_data_home
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
  use_temp_data_home()

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
  local data_home = use_temp_data_home()

  it('picks the review with the most overlap with HEAD subjects', function()
    write_review(data_home.root, 'feature', { 's1', 's2', 's3' }, 100)
    write_review(data_home.root, 'other', { 's3', 'x9' }, 200)

    -- feature shares s1,s2,s3 (3); other shares only s3 (1).
    eq(persistence.branch_by_subjects('repo', { s1 = true, s2 = true, s3 = true }), 'feature')
  end)

  it('breaks equal overlap toward the most recently used review', function()
    write_review(data_home.root, 'older', { 's1', 's2' }, 100)
    write_review(data_home.root, 'newer', { 's1', 's2' }, 200)

    eq(persistence.branch_by_subjects('repo', { s1 = true, s2 = true }), 'newer')
  end)

  it('returns nil when overlap is below the threshold (coincidental)', function()
    write_review(data_home.root, 'feature', { 's1', 's2', 's3' }, 100)

    -- Only one shared subject — not enough to claim HEAD.
    eq(persistence.branch_by_subjects('repo', { s1 = true, z = true }), nil)
  end)

  it('returns nil when no review exists for the repo', function()
    eq(persistence.branch_by_subjects('repo', { s1 = true, s2 = true }), nil)
  end)
end)

describe('ReviewPersistence.evict_lru:', function()
  local data_home = use_temp_data_home()

  -- Create a branch dir holding a state file with the given mtime (seconds).
  local function write_branch(name, mtime)
    local dir = data_home.root .. '/vgit/repo/' .. name
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
    local empty = data_home.root .. '/vgit/repo/empty'
    local objects_only = data_home.root .. '/vgit/repo/objects-only/objects'
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
  -- A fresh data home per spec, so the per-state-dir memo never carries over
  local data_home = use_temp_data_home()
  local dir

  before_each(function()
    dir = data_home.root .. '/vgit/repo/feature'
    vim.fn.mkdir(dir, 'p')
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
    eq(vim.fn.glob(dir .. '/*.tmp'), '')
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

  it('sweeps nothing while a state file is unreadable', function()
    write_state('by_file.json', approved('a.lua', 'shared'), 2000)
    -- A newer vgit's file may reference any object
    write_state('by_commit.json', { version = 2, entries = { ['s:a.lua'] = { approved = 'newer' } } }, 2000)
    persistence.write_objects('repo', 'feature', { shared = { 's' }, newer = { 'n' } })

    persistence.sweep_objects('repo', 'feature')
    eq(persistence.read_object('repo', 'feature', 'newer'), { 'n' })
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

describe('ReviewPersistence v1 state file:', function()
  local data_home = use_temp_data_home()

  local A_LINES, A_HASH = { 'local a = 1', 'return a' }, 'c4bf756b1652fb667f82201cce2ec25db186b580efec27cf901074da364f4c14'
  local BASE_LINES, BASE_HASH = { 'return 1' }, '486d9affb60dbb0063b03d8e23a6ccf6364ce203dc3a9f56f20e750eb41ecade'
  local EMPTY_HASH = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

  -- A by_commit state file as vgit writes it. Live sessions on different
  -- vgit versions share these files, so this must keep loading as is, and
  -- saves must keep writing the same fields.
  local FIXTURE = [[{"version":1,"lastUsed":1761200000,"branchName":"feature/x","entries":{]]
    .. [["8df4a362:src/a.lua":{"approved":"]] .. A_HASH .. [[","base":"]] .. BASE_HASH
    .. [[","change_id":"kzlnmouooqvwmnwmymlvpmmsuopnlkkt"},]]
    .. [["7d0c6595:gone.lua":{"approved":"]] .. EMPTY_HASH .. [[","base":"]] .. BASE_HASH .. [[","deleted":true}}}]]

  local function branch_dir()
    return data_home.root .. '/vgit/repo/feature--x'
  end

  local function write_fixture()
    vim.fn.mkdir(branch_dir() .. '/objects', 'p')
    vim.fn.writefile({ FIXTURE }, branch_dir() .. '/by_commit.json')
    vim.fn.writefile(A_LINES, branch_dir() .. '/objects/' .. A_HASH)
    vim.fn.writefile(BASE_LINES, branch_dir() .. '/objects/' .. BASE_HASH)
    vim.fn.writefile({}, branch_dir() .. '/objects/' .. EMPTY_HASH)
  end

  local function read_json()
    return vim.json.decode(table.concat(vim.fn.readfile(branch_dir() .. '/by_commit.json'), '\n'))
  end

  local function keys(t)
    local result = vim.tbl_keys(t)
    table.sort(result)
    return result
  end

  local function object_names()
    local names = vim.fn.readdir(branch_dir() .. '/objects')
    table.sort(names)
    return names
  end

  local function new_state()
    return review.fresh_review_state()({ branch_name = 'feature/x', review_type = 'by_commit', repo_name = 'repo' })
  end

  it('loads a frozen v1 by_commit state file', function()
    write_fixture()
    review.run(function()
      local state = new_state()
      state:load_from_disk()

      eq(state:get_approved('8df4a362:src/a.lua'), {
        lines = A_LINES,
        deleted = false,
        base_lines = BASE_LINES,
        hash = A_HASH,
        base_hash = BASE_HASH,
      })
      eq(state:get_approved('7d0c6595:gone.lua').lines, {})
      eq(state:get_approved('7d0c6595:gone.lua').deleted, true)

      state:save()
    end)

    local fixture, written = vim.json.decode(FIXTURE), read_json()
    eq(keys(written), keys(fixture))
    eq(written.entries, fixture.entries)
    eq(written.branchName, 'feature/x')
    eq(written.version, 1)
    eq(object_names(), keys({ [A_HASH] = true, [BASE_HASH] = true, [EMPTY_HASH] = true }))
  end)

  it('saves the same state file and objects after a restart', function()
    review.run(function()
      local state = new_state()
      state:set_approved('8df4a362:src/a.lua', A_LINES, false, BASE_LINES)
      state:set_approved('7d0c6595:gone.lua', {}, true, BASE_LINES)
      state:save()
    end)
    local before, objects = read_json(), object_names()

    review.run(function()
      local state = new_state()
      state:load_from_disk()
      state:save()
    end)
    local after = read_json()
    before.lastUsed, after.lastUsed = nil, nil
    eq(after, before)
    eq(object_names(), objects)
  end)
end)
