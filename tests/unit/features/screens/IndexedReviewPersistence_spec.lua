local persistence = require('vgit.features.screens.IndexedReviewPersistence')

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

describe('IndexedReviewPersistence snapshot objects:', function()
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
    -- by an .age secret inside an indexed commit review.
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

describe('IndexedReviewPersistence.branch_by_subjects:', function()
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
