local GitHunk = require('vgit.git.GitHunk')

local eq = assert.are.same

describe('GitHunk:', function()
  describe('new', function()
    it('should create a new Hunk object', function()
      local headers = {
        add = '@@ -17,0 +18,15 @@ foo bar',
        remove = '@@ -9,9 +8,0 @@ @@ foo bar',
        change = '@@ -10,7 +10,7 @@ foo bar',
        invalid = '@@ --10,-1 +-10,-7 @@ foo bar',
        invalid_zero = '@@ -0,0 +0,0 @@ foo bar',
      }

      eq(GitHunk(headers['add']), {
        header = '@@ -17,0 +18,15 @@ foo bar',
        diff = {},
        top = 18,
        bot = 32,
        type = 'add',
        stat = {
          added = 0,
          removed = 0,
        },
      })
      eq(GitHunk(headers['remove']), {
        header = '@@ -9,9 +8,0 @@ @@ foo bar',
        diff = {},
        top = 8,
        bot = 8,
        type = 'remove',
        stat = {
          added = 0,
          removed = 0,
        },
      })
      eq(GitHunk(headers['change']), {
        header = '@@ -10,7 +10,7 @@ foo bar',
        diff = {},
        top = 10,
        bot = 16,
        type = 'change',
        stat = {
          added = 0,
          removed = 0,
        },
      })
      eq(GitHunk(headers['invalid']), {
        header = '@@ --10,-1 +-10,-7 @@ foo bar',
        diff = {},
        top = -10,
        bot = -18,
        type = 'change',
        stat = {
          added = 0,
          removed = 0,
        },
      })
      eq(GitHunk(headers['invalid_zero']), {
        header = '@@ -0,0 +0,0 @@ foo bar',
        diff = {},
        top = 0,
        bot = 0,
        type = 'remove',
        stat = {
          added = 0,
          removed = 0,
        },
      })
    end)
  end)

  local function make_hunk(header, diff)
    local hunk = GitHunk(header)
    for _, line in ipairs(diff) do
      hunk:push(line)
    end
    return hunk
  end

  describe('invert', function()
    it('should swap sides and flip lines of a change hunk', function()
      local hunk = make_hunk('@@ -3,2 +4,3 @@', { '-a', '-b', '+A', '+B', '+C' })
      local inverted = hunk:invert()

      eq(inverted.header, '@@ -4,3 +3,2 @@')
      eq(inverted.diff, { '-A', '-B', '-C', '+a', '+b' })
      eq(inverted.type, 'change')
    end)

    it('should turn a deletion into an insertion anchored by the new side', function()
      local hunk = make_hunk('@@ -9,2 +10,0 @@', { '-l9', '-l10' })
      local inverted = hunk:invert()

      eq(inverted.header, '@@ -10,0 +9,2 @@')
      eq(inverted.diff, { '+l9', '+l10' })
      eq(inverted.type, 'add')
    end)

    it('should round trip back to the original', function()
      local hunk = make_hunk('@@ -7,0 +8,2 @@', { '+A', '+B' })
      local back = hunk:invert():invert()

      eq(back.header, hunk.header)
      eq(back.diff, hunk.diff)
      eq(back.type, hunk.type)
    end)
  end)

  describe('select_rows', function()

    it('should return self when the selection covers the whole hunk', function()
      local hunk = make_hunk('@@ -10,2 +10,2 @@', { '-a', '-b', '+A', '+B' })
      assert.is_true(hunk:select_rows({ [1] = true, [2] = true }) == hunk)
    end)

    it('should return nil for an empty selection', function()
      local hunk = make_hunk('@@ -10,2 +10,2 @@', { '-a', '-b', '+A', '+B' })
      eq(hunk:select_rows({}), nil)
    end)

    it('should slice a middle row span of a change hunk', function()
      local hunk = make_hunk('@@ -10,4 +10,4 @@', { '-a', '-b', '-c', '-d', '+A', '+B', '+C', '+D' })
      local sub = hunk:select_rows({ [2] = true, [3] = true })

      eq(sub.header, '@@ -11,2 +11,2 @@')
      eq(sub.diff, { '-b', '-c', '+B', '+C' })
      eq(sub.type, 'change')
    end)

    it('should slice rows of a pure add hunk keeping the anchor', function()
      local hunk = make_hunk('@@ -17,0 +18,3 @@', { '+A', '+B', '+C' })
      local sub = hunk:select_rows({ [2] = true })

      -- Anchor stays: insertion still happens after old line 17
      eq(sub.header, '@@ -17,0 +19,1 @@')
      eq(sub.diff, { '+B' })
      eq(sub.type, 'add')
    end)

    it('should slice rows of a pure remove hunk', function()
      local hunk = make_hunk('@@ -9,3 +8,0 @@', { '-a', '-b', '-c' })
      local sub = hunk:select_rows({ [2] = true, [3] = true })

      eq(sub.header, '@@ -10,2 +8,0 @@')
      eq(sub.diff, { '-b', '-c' })
      eq(sub.type, 'remove')
    end)

    it('should turn an uneven tail selection into a pure insertion after the old span', function()
      -- 2 removed lines pair with the first 2 added; rows 3-4 are extra adds
      local hunk = make_hunk('@@ -10,2 +10,4 @@', { '-a', '-b', '+A', '+B', '+C', '+D' })
      local sub = hunk:select_rows({ [3] = true, [4] = true })

      -- No removed rows selected: anchor after the hunk's last old line (11)
      eq(sub.header, '@@ -11,0 +12,2 @@')
      eq(sub.diff, { '+C', '+D' })
      eq(sub.type, 'add')
    end)

    it('should turn a deletion-only selection into a pure removal', function()
      -- 4 removed lines, 2 added: rows 3-4 have no added pair
      local hunk = make_hunk('@@ -10,4 +10,2 @@', { '-a', '-b', '-c', '-d', '+A', '+B' })
      local sub = hunk:select_rows({ [3] = true, [4] = true })

      eq(sub.header, '@@ -12,2 +11,0 @@')
      eq(sub.diff, { '-c', '-d' })
      eq(sub.type, 'remove')
    end)

    it('should slice the head of a change hunk', function()
      local hunk = make_hunk('@@ -10,3 +10,3 @@', { '-a', '-b', '-c', '+A', '+B', '+C' })
      local sub = hunk:select_rows({ [1] = true })

      eq(sub.header, '@@ -10,1 +10,1 @@')
      eq(sub.diff, { '-a', '+A' })
      eq(sub.type, 'change')
    end)
  end)
end)
