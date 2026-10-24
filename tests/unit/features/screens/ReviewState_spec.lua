-- Not a module path: plenary runs specs without the repo root on package.path
local review = dofile('tests/helpers/review.lua')
local ReviewState = require('vgit.features.screens.ReviewState')
local persistence = require('vgit.features.screens.ReviewPersistence')

local eq = assert.are.same
local run = review.run

describe('ReviewState', function()
  review.use_temp_data_home()

  describe('session store:', function()
    local function trunk_review(repo_name)
      return ReviewState({ branch_name = 'main', review_type = 'by_file', repo_name = repo_name })
    end

    it("keeps one repo's records out of another repo's review of the same branch", function()
      run(function()
        local a = trunk_review('repo-a')
        a:load_from_disk()
        a:set_approved('README.md', { 'repo A readme' }, false, { 'old' })
        a:save()

        local b = trunk_review('repo-b')
        b:load_from_disk()
        eq(b:get_approved('README.md'), nil)

        b:save()
        eq(persistence.load('repo-b', 'main', 'by_file').entries['README.md'], nil)
      end)
    end)

    it('drops records whose state file was deleted since', function()
      run(function()
        local state = trunk_review('repo')
        state:set_approved('README.md', { 'approved' }, false, { 'old' })
        state:save()

        vim.fn.delete(persistence.get_state_path('repo', 'main', 'by_file'))
        local reopened = trunk_review('repo')
        reopened:load_from_disk()
        eq(reopened:get_approved('README.md'), nil)
      end)
    end)
  end)

  describe('unusable state files:', function()
    local console = require('vgit.core.console')
    local path, warnings, warn

    before_each(function()
      path = persistence.get_state_path('repo', 'feature', 'by_file')
      vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
      warnings, warn = {}, console.warn
      console.warn = function(msg) warnings[#warnings + 1] = msg end
    end)
    after_each(function() console.warn = warn end)

    local function feature_review()
      local state = review.fresh_review_state()({ branch_name = 'feature', review_type = 'by_file', repo_name = 'repo' })
      state:load_from_disk()
      return state
    end

    it('leaves a file from a newer vgit untouched', function()
      local newer = '{"version":2,"entries":{"a.lua":{"approved":"h"}}}'
      vim.fn.writefile({ newer }, path)
      run(function()
        local state = feature_review()
        state:set_approved('b.lua', { 'b' }, false, { 'old' })
        state:save()
      end)
      eq(vim.fn.readfile(path), { newer })
      eq(#warnings, 1)
    end)

    it('starts fresh from a corrupt file and replaces it on save', function()
      vim.fn.writefile({ '{"version":1,"entr' }, path)
      run(function()
        local state = feature_review()
        state:set_approved('b.lua', { 'b' }, false, { 'old' })
        state:save()
      end)
      eq(vim.tbl_keys(persistence.load('repo', 'feature', 'by_file').entries), { 'b.lua' })
      eq(#warnings, 1)
    end)
  end)

  describe('failed writes:', function()
    local console = require('vgit.core.console')
    local fs = require('vgit.core.fs')
    local warnings, warn, write_file_atomic

    before_each(function()
      warnings, warn, write_file_atomic = {}, console.warn, fs.write_file_atomic
      console.warn = function(msg) warnings[#warnings + 1] = msg end
    end)
    after_each(function()
      console.warn, fs.write_file_atomic = warn, write_file_atomic
    end)

    it('keeps the saved state when an object fails to write', function()
      run(function()
        local state = ReviewState({ branch_name = 'feature', review_type = 'by_file', repo_name = 'repo' })
        state:set_approved('a.lua', { 'a' }, false, { 'old' })
        state:save()

        fs.write_file_atomic = function(path, lines)
          if path:find('/objects/') then return nil, { 'No space left on device' } end
          return write_file_atomic(path, lines)
        end
        state:set_approved('b.lua', { 'b' }, false, { 'old' })
        state:save()
      end)

      eq(vim.tbl_keys(persistence.load('repo', 'feature', 'by_file').entries), { 'a.lua' })
      eq(warnings, { 'Failed to save review state: No space left on device' })
    end)
  end)

  it('drops a record whose base object is gone', function()
    run(function()
      local state = review.fresh_review_state()({ branch_name = 'feature', review_type = 'by_file', repo_name = 'repo' })
      state:set_approved('a.lua', { 'a' }, false, { 'old' })
      state:save()
      local base_hash = persistence.hash_lines({ 'old' })
      local branch_dir = vim.fn.fnamemodify(persistence.get_state_path('repo', 'feature', 'by_file'), ':h')
      vim.fn.delete(branch_dir .. '/objects/' .. base_hash)

      local reopened = review.fresh_review_state()({ branch_name = 'feature', review_type = 'by_file', repo_name = 'repo' })
      reopened:load_from_disk()
      eq(reopened:get_approved('a.lua'), nil)
    end)
  end)

  it('keeps the base hash when marking again against the same base', function()
    run(function()
      local state = review.fresh_review_state()({ branch_name = 'feature', review_type = 'by_file', repo_name = 'repo' })
      local base = { 'old' }
      state:set_approved('a.lua', { 'a' }, false, base)
      state:save()

      state:set_approved('a.lua', { 'a2' }, false, base)
      eq(state:get_approved('a.lua').base_hash, persistence.hash_lines(base))
    end)
  end)

  describe('write-behind save:', function()
    it('saves within its delay while marks keep coming', function()
      local state = review.fresh_review_state()({ branch_name = 'feature', review_type = 'by_file', repo_name = 'repo' })
      local path = persistence.get_state_path('repo', 'feature', 'by_file')

      -- Marks 600 ms apart: a restarting debounce would never fire
      state:set_approved('a.lua', { 'a' }, false, { 'old' })
      vim.wait(600)
      state:set_approved('b.lua', { 'b' }, false, { 'old' })
      vim.wait(600)
      state:set_approved('c.lua', { 'c' }, false, { 'old' })
      assert(vim.wait(200, function() return vim.loop.fs_stat(path) ~= nil end, 10), 'not saved yet')

      local entries = persistence.load('repo', 'feature', 'by_file').entries
      eq(entries['a.lua'] ~= nil and entries['b.lua'] ~= nil, true)
      run(function() state:save() end)
    end)
  end)

  describe('concurrent sessions:', function()
    -- One nvim session's review of the shared state file
    local function session()
      local state = review.fresh_review_state()({ branch_name = 'feature', review_type = 'by_file', repo_name = 'repo' })
      state:load_from_disk()
      return state
    end

    local function saved_lines()
      local lines = {}
      for key, entry in pairs(persistence.load('repo', 'feature', 'by_file').entries) do
        lines[key] = persistence.read_object('repo', 'feature', entry.approved)[1]
      end
      return lines
    end

    it("keeps another session's marks made while this one was open", function()
      run(function()
        local this = session()
        local other = session()
        other:set_approved('g.lua', { 'g' }, false, { 'old' })
        other:save()

        this:set_approved('f.lua', { 'f' }, false, { 'old' })
        this:save()
      end)
      -- The final save's sweep kept the other session's object too
      eq(saved_lines(), { ['f.lua'] = 'f', ['g.lua'] = 'g' })
    end)

    it("takes another session's changes to keys this one didn't change", function()
      run(function()
        local first = session()
        first:set_approved('a.lua', { 'a' }, false, { 'old' })
        first:set_approved('b.lua', { 'b' }, false, { 'old' })
        first:save()

        local this, other = session(), session()
        other:remove_approved('a.lua')
        other:set_approved('b.lua', { 'b2' }, false, { 'old' })
        other:save()

        this:set_approved('c.lua', { 'c' }, false, { 'old' })
        this:save()
        eq(this:get_approved('a.lua'), nil)
      end)
      eq(saved_lines(), { ['b.lua'] = 'b2', ['c.lua'] = 'c' })
    end)

    it('keeps its own changes over the other session', function()
      run(function()
        local this, other = session(), session()
        other:set_approved('a.lua', { 'theirs' }, false, { 'old' })
        other:save()

        this:set_approved('a.lua', { 'mine' }, false, { 'old' })
        this:save()
      end)
      eq(saved_lines(), { ['a.lua'] = 'mine' })
    end)

    it("merges another session's write into a pending write-behind save", function()
      local this, path
      run(function()
        this = session()
        path = persistence.get_state_path('repo', 'feature', 'by_file')
        this:set_approved('f.lua', { 'f' }, false, { 'old' })

        local other = session()
        other:set_approved('g.lua', { 'g' }, false, { 'old' })
        other:save()
      end)
      local before = vim.loop.fs_stat(path).ino
      assert(vim.wait(2000, function() return vim.loop.fs_stat(path).ino ~= before end, 10), 'no write-behind save')
      eq(saved_lines(), { ['f.lua'] = 'f', ['g.lua'] = 'g' })

      -- Then a later change of this session's own doesn't undo the merge
      run(function()
        this:set_approved('h.lua', { 'h' }, false, { 'old' })
        this:save()
      end)
      eq(saved_lines(), { ['f.lua'] = 'f', ['g.lua'] = 'g', ['h.lua'] = 'h' })
    end)
  end)
end)
