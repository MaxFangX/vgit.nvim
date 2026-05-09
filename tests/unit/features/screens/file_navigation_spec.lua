local file_navigation = require('vgit.features.screens.file_navigation')

local eq = assert.are.same

-- Shorthand for building a file entry as it appears in screen models.
local function f(filepath, type)
  return { status = { filepath = filepath }, type = type }
end

-- Shorthand for a `{filepath, commit_hash}` ref returned by find_adjacent_files.
local function ref(filepath, commit_hash)
  return { filepath = filepath, commit_hash = commit_hash }
end

local function any_type() return true end

describe('file_navigation:', function()
  describe('build_logical_file_list', function()
    it('returns empty for nil or empty entries', function()
      eq(file_navigation.build_logical_file_list(nil), {})
      eq(file_navigation.build_logical_file_list({}), {})
    end)

    it('flattens by-file entries and tags them with section', function()
      local entries = {
        { title = 'Staged Changes', entries = { f('b.lua', 'staged') } },
        { title = 'Changes',        entries = { f('a.lua', 'unstaged'), f('c.lua', 'unstaged') } },
      }
      local out = file_navigation.build_logical_file_list(entries)
      eq(#out, 3)
      eq(out[1].section, 'Staged Changes')
      eq(out[1].file.status.filepath, 'b.lua')
      eq(out[1].commit_hash, nil)
      eq(out[2].section, 'Changes')
      eq(out[2].file.status.filepath, 'a.lua')
      eq(out[3].file.status.filepath, 'c.lua')
    end)

    it('flattens by-commit entries and tags them with commit_hash', function()
      local entries = {
        {
          title = 'Unseen',
          commits = {
            {
              commit = { hash = 'abc' },
              files = { f('b.lua', 'unseen'), f('a.lua', 'unseen') },
            },
            {
              commit = { hash = 'def' },
              files = { f('z.lua', 'unseen') },
            },
          },
        },
      }
      local out = file_navigation.build_logical_file_list(entries)
      eq(#out, 3)
      -- Files within a commit are sorted alphabetically.
      eq(out[1].commit_hash, 'abc')
      eq(out[1].file.status.filepath, 'a.lua')
      eq(out[2].commit_hash, 'abc')
      eq(out[2].file.status.filepath, 'b.lua')
      eq(out[3].commit_hash, 'def')
      eq(out[3].file.status.filepath, 'z.lua')
    end)

    it('orders folders before files at each level (by-file)', function()
      local entries = {
        {
          title = 'Changes',
          entries = {
            f('zeta.lua',     'unstaged'),
            f('alpha.lua',    'unstaged'),
            f('src/foo.lua',  'unstaged'),
            f('src/bar.lua',  'unstaged'),
          },
        },
      }
      local out = file_navigation.build_logical_file_list(entries)
      local paths = {}
      for _, info in ipairs(out) do paths[#paths + 1] = info.file.status.filepath end
      -- src/ folder comes before top-level files; within src/, alphabetical;
      -- top-level files alphabetical.
      eq(paths, { 'src/bar.lua', 'src/foo.lua', 'alpha.lua', 'zeta.lua' })
    end)
  end)

  describe('find_adjacent_files', function()
    -- Helper: build all_files of unstaged-type entries with optional staged
    -- entries at the start (matching the section ordering in fetch()).
    local function make_files(specs)
      local out = {}
      for _, spec in ipairs(specs) do
        out[#out + 1] = {
          section = spec.section or 'Changes',
          commit_hash = spec.commit_hash,
          file = f(spec.filepath, spec.type or 'unstaged'),
        }
      end
      return out
    end

    it('returns all nil for empty input', function()
      local n, p, fst = file_navigation.find_adjacent_files({}, 'a.lua', nil, any_type)
      eq(n, nil); eq(p, nil); eq(fst, nil)
    end)

    it('current is the only match: first=self, prev=nil, next=nil', function()
      local files = make_files({ { filepath = 'only.lua' } })
      local n, p, fst = file_navigation.find_adjacent_files(files, 'only.lua', nil, any_type)
      eq(n, nil)
      eq(p, nil)
      eq(fst, ref('only.lua'))
    end)

    it('current at start: next=second, prev=nil, first=self', function()
      local files = make_files({
        { filepath = 'a.lua' }, { filepath = 'b.lua' }, { filepath = 'c.lua' },
      })
      local n, p, fst = file_navigation.find_adjacent_files(files, 'a.lua', nil, any_type)
      eq(n, ref('b.lua'))
      eq(p, nil)
      eq(fst, ref('a.lua'))
    end)

    it('current at end: next=nil, prev=second-to-last, first=first', function()
      local files = make_files({
        { filepath = 'a.lua' }, { filepath = 'b.lua' }, { filepath = 'c.lua' },
      })
      local n, p, fst = file_navigation.find_adjacent_files(files, 'c.lua', nil, any_type)
      eq(n, nil)
      eq(p, ref('b.lua'))
      eq(fst, ref('a.lua'))
    end)

    it('current in middle: all three set', function()
      local files = make_files({
        { filepath = 'a.lua' }, { filepath = 'b.lua' },
        { filepath = 'c.lua' }, { filepath = 'd.lua' },
      })
      local n, p, fst = file_navigation.find_adjacent_files(files, 'c.lua', nil, any_type)
      eq(n, ref('d.lua'))
      eq(p, ref('b.lua'))
      eq(fst, ref('a.lua'))
    end)

    it('predicate filters out non-matching items', function()
      -- Mimics fetch()'s order: staged section before unstaged section.
      local files = make_files({
        { section = 'Staged Changes', filepath = 'a.lua', type = 'staged' },
        { section = 'Staged Changes', filepath = 'b.lua', type = 'staged' },
        { section = 'Changes',        filepath = 'a.lua', type = 'unstaged' },
        { section = 'Changes',        filepath = 'b.lua', type = 'unstaged' },
        { section = 'Changes',        filepath = 'c.lua', type = 'unstaged' },
      })
      local function unstaged(info) return info.file.type == 'unstaged' end

      -- Current = c (last unstaged): first should be a.lua (first unstaged,
      -- skipping the staged-section entries entirely), prev = b, next = nil.
      -- This is the regression case: the user is on the last unstaged file.
      local n, p, fst = file_navigation.find_adjacent_files(files, 'c.lua', nil, unstaged)
      eq(n, nil)
      eq(p, ref('b.lua'))
      eq(fst, ref('a.lua'))
    end)

    it('current not in filtered list: prev tracks last match, next=nil', function()
      local files = make_files({
        { filepath = 'a.lua' }, { filepath = 'b.lua' }, { filepath = 'c.lua' },
      })
      -- Walking the loop with current='zzz' (never matches): we never set
      -- found_current, so each match becomes prev_file (overwriting).
      -- next stays nil; first is the first match.
      local n, p, fst = file_navigation.find_adjacent_files(files, 'zzz.lua', nil, any_type)
      eq(n, nil)
      eq(p, ref('c.lua'))
      eq(fst, ref('a.lua'))
    end)

    it('commit_hash disambiguates same filepath across commits', function()
      local files = make_files({
        { filepath = 'shared.lua', commit_hash = 'abc' },
        { filepath = 'other.lua',  commit_hash = 'abc' },
        { filepath = 'shared.lua', commit_hash = 'def' },
      })
      -- current = shared.lua@def, NOT shared.lua@abc
      local n, p, fst = file_navigation.find_adjacent_files(files, 'shared.lua', 'def', any_type)
      eq(n, nil)
      eq(p, ref('other.lua', 'abc'))
      eq(fst, ref('shared.lua', 'abc'))
    end)

    it('without current_commit, matches the first occurrence by filepath', function()
      local files = make_files({
        { filepath = 'shared.lua', commit_hash = 'abc' },
        { filepath = 'other.lua',  commit_hash = 'abc' },
        { filepath = 'shared.lua', commit_hash = 'def' },
      })
      -- current_commit = nil: shared.lua@abc matches first.
      local n, p, fst = file_navigation.find_adjacent_files(files, 'shared.lua', nil, any_type)
      eq(n, ref('other.lua', 'abc'))
      eq(p, nil)
      eq(fst, ref('shared.lua', 'abc'))
    end)
  end)
end)
