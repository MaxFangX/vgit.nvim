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

  describe('adjacent_commit_target', function()
    -- Build all_files from {commit, path, section?} specs.
    local function make(specs)
      local out = {}
      for _, s in ipairs(specs) do
        out[#out + 1] = {
          section = s.section or 'Unseen',
          commit_hash = s.commit,
          file = f(s.path, 'unseen'),
        }
      end
      return out
    end

    -- Three commits: abc=[1,2], def=[3], ghi=[4,5].
    local files = make({
      { commit = 'abc', path = 'a.lua' },
      { commit = 'abc', path = 'b.lua' },
      { commit = 'def', path = 'c.lua' },
      { commit = 'ghi', path = 'd.lua' },
      { commit = 'ghi', path = 'e.lua' },
    })
    local function target(idx, dir)
      return file_navigation.adjacent_commit_target(files, idx, dir)
    end

    it("'next' from a commit's first file lands on the next commit's first file", function()
      eq(target(1, 'next'), 3) -- abc first file -> def first file
    end)

    it("'next' from a commit's last file lands on the next commit's first file", function()
      eq(target(2, 'next'), 3) -- abc last file -> def first file
    end)

    it("'next' from a single-file commit crosses to the next commit", function()
      eq(target(3, 'next'), 4) -- def (sole file) -> ghi first file
    end)

    it("'next' wraps from the last commit to the first", function()
      eq(target(5, 'next'), 1) -- ghi last file -> abc first file
    end)

    it("'prev' from a commit's last file lands on the previous commit's last file", function()
      eq(target(5, 'prev'), 3) -- ghi last file -> def last file
    end)

    it("'prev' from a commit's first file lands on the previous commit's last file", function()
      eq(target(4, 'prev'), 3) -- ghi first file -> def last file
    end)

    it("'prev' from a single-file commit crosses to the previous commit", function()
      eq(target(3, 'prev'), 2) -- def (sole file) -> abc last file
    end)

    it("'prev' wraps from the first commit to the last", function()
      eq(target(1, 'prev'), 5) -- abc first file -> ghi last file
    end)

    it('section distinguishes a commit that spans Unseen and Seen', function()
      -- The same hash appears in both sections as two separate ranges.
      local split = make({
        { section = 'Unseen', commit = 'abc', path = 'a.lua' },
        { section = 'Seen',   commit = 'abc', path = 'b.lua' },
      })
      -- Each section's range counts as its own commit, so J/K cross between them.
      eq(file_navigation.adjacent_commit_target(split, 1, 'next'), 2)
      eq(file_navigation.adjacent_commit_target(split, 2, 'prev'), 1)
    end)
  end)

  describe('hunk_past_position', function()
    local function marks(tops)
      local out = {}
      for _, top in ipairs(tops) do
        out[#out + 1] = { top_relative = top }
      end
      return out
    end

    it('skips the leading remainder of a partially marked hunk', function()
      -- A hunk at lines 2-9 with 4-6 marked splits into remainders at 2-3 and
      -- 7-9: the leading remainder keeps start line 2, so land on 7-9.
      eq(file_navigation.hunk_past_position(marks({ 2, 7 }), 2), 2)
    end)

    it('lands on the hunk that slid into a fully marked slot', function()
      eq(file_navigation.hunk_past_position(marks({ 1, 20 }), 10), 2)
    end)

    it('returns nil when nothing starts past the mark', function()
      -- Marked the file's last hunk: review moves on to the next file even
      -- though an earlier hunk remains.
      eq(file_navigation.hunk_past_position(marks({ 2, 10 }), 10), nil)
    end)
  end)
end)
