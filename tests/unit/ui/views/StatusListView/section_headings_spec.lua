local section_headings = require('vgit.ui.views.StatusListView.section_headings')

local function file(name)
  return { node_type = 'file', value = name }
end

local function folder(name, items)
  return { node_type = 'folder', value = name, items = items }
end

local function top(title, items)
  return { value = title, items = items }
end

-- Compute headings for `folds` and return a sorted list of their names.
local function compute(folds)
  local out = {}
  for node, _ in pairs(section_headings(folds)) do
    out[#out + 1] = node.value
  end
  table.sort(out)
  return out
end

local eq = assert.are.same

describe('StatusListView.section_headings:', function()
  it('returns empty table for nil/empty folds', function()
    eq(compute(nil), {})
    eq(compute({}), {})
  end)

  it('marks crate folders under a single-folder chain (5-file Changes)', function()
    -- public has 3 crate folders + 1 orphan Cargo.lock file. Each crate
    -- folder is the topmost folder containing its own group of files.
    local folds = {
      top('Changes', {
        folder('public', {
          folder('lexe', { folder('src', { file('wallet.rs') }) }),
          folder('lexe-payment-uri', { file('Cargo.toml') }),
          folder('lexe-payment-uri-core', {
            folder('src', { file('bip321_uri.rs'), file('lightning_uri.rs') }),
          }),
          file('Cargo.lock'),
        }),
      }),
    }
    eq(compute(folds), { 'lexe', 'lexe-payment-uri', 'lexe-payment-uri-core' })
  end)

  it('skips top-level fold even when it has multiple direct children', function()
    -- Regression: a Cargo.lock file at the top-level fold's items used to
    -- cause my algorithm to mark "public" as the heading instead of
    -- descending into public to find lexe/lp-uri/lp-uri-core.
    local folds = {
      top('Changes', {
        folder('public', {
          folder('lexe', { folder('src', { file('wallet.rs') }) }),
          folder('lexe-payment-uri', {
            folder('src', { file('bip353.rs'), file('lib.rs') }),
            file('Cargo.toml'),
          }),
          folder('lexe-payment-uri-core', {
            folder('src', { file('bip321_uri.rs'), file('lib.rs') }),
          }),
          file('Cargo.lock'),
        }),
        file('Cargo.lock'), -- root-level Cargo.lock: sibling of public
      }),
    }
    eq(compute(folds), { 'lexe', 'lexe-payment-uri', 'lexe-payment-uri-core' })
  end)

  it('marks the topmost folder when single-folder chain ends in a file', function()
    -- Staged > public > foo > bar.rs: no branching anywhere. The topmost
    -- folder containing the one group is "public".
    local folds = {
      top('Staged Changes', {
        folder('public', { folder('foo', { file('bar.rs') }) }),
      }),
    }
    eq(compute(folds), { 'public' })
  end)

  it('does not descend past a marked folder (no nested headings)', function()
    -- lexe-payment-uri itself branches into src + Cargo.toml, but should
    -- still be marked as a single heading (not split into src + Cargo.toml).
    local folds = {
      top('Changes', {
        folder('public', {
          folder('lexe-payment-uri', {
            folder('src', { file('a.rs'), file('b.rs') }),
            file('Cargo.toml'),
          }),
          folder('other', { file('x.rs') }),
        }),
      }),
    }
    eq(compute(folds), { 'lexe-payment-uri', 'other' })
  end)

  it('skips orphan files at the top level (no folder wraps them)', function()
    local folds = {
      top('Changes', {
        file('foo.rs'),
        file('bar.rs'),
      }),
    }
    eq(compute(folds), {})
  end)

  it('handles multiple top-level folds independently', function()
    -- e.g. both Staged Changes and Changes are present.
    local folds = {
      top('Staged Changes', {
        folder('crate-a', { folder('src', { file('a.rs') }) }),
      }),
      top('Changes', {
        folder('crate-b', { folder('src', { file('b.rs') }) }),
      }),
    }
    eq(compute(folds), { 'crate-a', 'crate-b' })
  end)

  it('marks each branchy folder when top-level has multiple folder siblings', function()
    -- E.g. repo without a single root prefix folder.
    local folds = {
      top('Changes', {
        folder('crate-a', { folder('src', { file('a.rs') }) }),
        folder('crate-b', { folder('src', { file('b.rs') }) }),
      }),
    }
    eq(compute(folds), { 'crate-a', 'crate-b' })
  end)

  it('marks a folder with only file children directly', function()
    -- foo > {a.rs, b.rs}: foo itself is the topmost folder for the group.
    local folds = {
      top('Changes', {
        folder('foo', { file('a.rs'), file('b.rs') }),
      }),
    }
    eq(compute(folds), { 'foo' })
  end)

  it('skips folders whose subtree contains no files', function()
    local folds = {
      top('Changes', {
        folder('empty', { folder('also-empty', {}) }),
        folder('has-files', { file('x.rs') }),
      }),
    }
    eq(compute(folds), { 'has-files' })
  end)
end)
