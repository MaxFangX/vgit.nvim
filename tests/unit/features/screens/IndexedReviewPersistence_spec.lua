local persistence = require('vgit.features.screens.IndexedReviewPersistence')

local eq = assert.are.same

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
