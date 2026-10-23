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
  vim.fn.writefile({ vim.fn.json_encode(data) }, dir .. '/by_commit_indexed.json')
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
    local path = dir .. '/by_commit_indexed.json'
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
    local newer = mixed .. '/by_commit.json'
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
