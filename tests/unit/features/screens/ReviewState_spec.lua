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
end)
