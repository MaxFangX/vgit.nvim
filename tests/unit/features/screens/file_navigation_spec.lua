local file_navigation = require('vgit.features.screens.file_navigation')

local eq = assert.are.same

-- Shorthand for a list file node (see BaseListView:file_nodes)
local function node(filepath, type, commit_hash)
  return {
    id = string.format('%s|%s|%s', commit_hash or '', filepath, type),
    entry = { status = { filepath = filepath }, type = type, commit_hash = commit_hash },
  }
end

-- Shorthand for a `{filepath}` ref returned by find_adjacent_files.
local function ref(filepath)
  return { filepath = filepath }
end

local function any_type() return true end

describe('file_navigation:', function()
  describe('find_adjacent_files', function()
    local function make_files(specs)
      return vim.tbl_map(function(spec) return node(spec.filepath, spec.type or 'unstaged') end, specs)
    end

    it('returns all nil for empty input', function()
      local n, p, fst = file_navigation.find_adjacent_files({}, 'a.lua', any_type)
      eq(n, nil); eq(p, nil); eq(fst, nil)
    end)

    it('current is the only match: first=self, prev=nil, next=nil', function()
      local files = make_files({ { filepath = 'only.lua' } })
      local n, p, fst = file_navigation.find_adjacent_files(files, 'only.lua', any_type)
      eq(n, nil)
      eq(p, nil)
      eq(fst, ref('only.lua'))
    end)

    it('current at start: next=second, prev=nil, first=self', function()
      local files = make_files({
        { filepath = 'a.lua' }, { filepath = 'b.lua' }, { filepath = 'c.lua' },
      })
      local n, p, fst = file_navigation.find_adjacent_files(files, 'a.lua', any_type)
      eq(n, ref('b.lua'))
      eq(p, nil)
      eq(fst, ref('a.lua'))
    end)

    it('current at end: next=nil, prev=second-to-last, first=first', function()
      local files = make_files({
        { filepath = 'a.lua' }, { filepath = 'b.lua' }, { filepath = 'c.lua' },
      })
      local n, p, fst = file_navigation.find_adjacent_files(files, 'c.lua', any_type)
      eq(n, nil)
      eq(p, ref('b.lua'))
      eq(fst, ref('a.lua'))
    end)

    it('current in middle: all three set', function()
      local files = make_files({
        { filepath = 'a.lua' }, { filepath = 'b.lua' },
        { filepath = 'c.lua' }, { filepath = 'd.lua' },
      })
      local n, p, fst = file_navigation.find_adjacent_files(files, 'c.lua', any_type)
      eq(n, ref('d.lua'))
      eq(p, ref('b.lua'))
      eq(fst, ref('a.lua'))
    end)

    it('predicate filters out non-matching items', function()
      -- Mimics fetch()'s order: staged section before unstaged section.
      local files = make_files({
        { filepath = 'a.lua', type = 'staged' },
        { filepath = 'b.lua', type = 'staged' },
        { filepath = 'a.lua', type = 'unstaged' },
        { filepath = 'b.lua', type = 'unstaged' },
        { filepath = 'c.lua', type = 'unstaged' },
      })
      local function unstaged(file) return file.entry.type == 'unstaged' end

      -- On the last unstaged file, first skips the staged section
      local n, p, fst = file_navigation.find_adjacent_files(files, 'c.lua', unstaged)
      eq(n, nil)
      eq(p, ref('b.lua'))
      eq(fst, ref('a.lua'))
    end)

    it('current not in filtered list: prev tracks last match, next=nil', function()
      local files = make_files({
        { filepath = 'a.lua' }, { filepath = 'b.lua' }, { filepath = 'c.lua' },
      })
      local n, p, fst = file_navigation.find_adjacent_files(files, 'zzz.lua', any_type)
      eq(n, nil)
      eq(p, ref('c.lua'))
      eq(fst, ref('a.lua'))
    end)
  end)

  describe('adjacent_commit_target', function()
    -- Build file nodes from {commit, path, type?} specs.
    local function make(specs)
      return vim.tbl_map(function(spec) return node(spec.path, spec.type or 'unseen', spec.commit) end, specs)
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
        { type = 'unseen', commit = 'abc', path = 'a.lua' },
        { type = 'seen',   commit = 'abc', path = 'b.lua' },
      })
      -- Each section's range counts as its own commit, so J/K cross between them.
      eq(file_navigation.adjacent_commit_target(split, 1, 'next'), 2)
      eq(file_navigation.adjacent_commit_target(split, 2, 'prev'), 1)
    end)
  end)

  describe('next_of_type', function()
    local files = {
      node('a.lua', 'seen'),
      node('a.lua', 'unseen'),
      node('b.lua', 'unseen'),
      node('c.lua', 'seen'),
    }
    local function next_of(i, type)
      local id = file_navigation.next_of_type(files, files[i].id, type)
      return id and vim.iter(ipairs(files)):find(function(_, file) return file.id == id end)
    end

    it('finds the next file of the type', function()
      eq(next_of(2, 'unseen'), 3)
      eq(next_of(1, 'seen'), 4)
    end)

    it('wraps around', function()
      eq(next_of(3, 'unseen'), 2)
      eq(next_of(4, 'seen'), 1)
    end)

    it('is nil when the file is the only one of its type', function()
      eq(file_navigation.next_of_type({ node('a.lua', 'unseen') }, node('a.lua', 'unseen').id, 'unseen'), nil)
    end)

    it('is nil for an unknown id', function()
      eq(file_navigation.next_of_type(files, 'nope', 'unseen'), nil)
    end)
  end)

  describe('should_cross_file', function()
    local cross = file_navigation.should_cross_file

    it('crosses when the file has no hunks', function()
      eq(cross('next', nil, 0, nil), true)
      eq(cross('prev', nil, 0, nil), true)
    end)

    it("'next' crosses only from inside the last hunk", function()
      eq(cross('next', 3, 3, 'inside'), true)
      eq(cross('next', 2, 3, 'inside'), false)
      eq(cross('next', 2, 3, 'between'), false)
      eq(cross('next', 1, 3, 'above'), false)
    end)

    it("'next' from below the last hunk lands on it first", function()
      eq(cross('next', 3, 3, 'below'), false)
    end)

    it("'prev' crosses only from inside the first hunk", function()
      eq(cross('prev', 1, 3, 'inside'), true)
      eq(cross('prev', 2, 3, 'inside'), false)
      eq(cross('prev', 1, 3, 'between'), false)
      eq(cross('prev', 3, 3, 'below'), false)
    end)

    it("'prev' from above the first hunk lands on it first", function()
      eq(cross('prev', 1, 3, 'above'), false)
    end)

    it('crosses from inside a lone hunk in either direction', function()
      eq(cross('next', 1, 1, 'inside'), true)
      eq(cross('prev', 1, 1, 'inside'), true)
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
