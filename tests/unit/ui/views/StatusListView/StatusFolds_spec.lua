local GitStatus = require('vgit.git.GitStatus')
local StatusFolds = require('vgit.ui.views.StatusListView.StatusFolds')
local ReviewModel = require('vgit.features.screens.ReviewModel')

local eq = assert.are.same

describe('StatusFolds:', function()
  describe('derive_status_hl', function()
    local function hl(value)
      return StatusFolds():derive_status_hl(GitStatus(value .. ' file.lua'))
    end

    it('colors staged, unstaged and unmerged statuses', function()
      eq('GitSignsAdd', hl('A '))
      eq('GitSignsAdd', hl('R '))
      eq('GitSignsDelete', hl('D '))
      eq('GitSignsChange', hl('M '))
      eq('GitSignsChange', hl('T '))
      eq('GitSignsAdd', hl('??'))
      eq('GitSignsAdd', hl(' A'))
      eq('GitSignsDelete', hl(' D'))
      eq('GitSignsChange', hl(' M'))
      eq('GitSignsChange', hl('UU'))
    end)

    it('colors review statuses like staged ones', function()
      local function review_status(char)
        return ReviewModel.new_item({ filepath = 'a "b".lua', status = char }, {}).status
      end
      local function review_hl(char)
        return StatusFolds():derive_status_hl(review_status(char))
      end
      eq('GitSignsAdd', review_hl('A'))
      eq('GitSignsAdd', review_hl('C'))
      eq('GitSignsDelete', review_hl('D'))
      eq('GitSignsChange', review_hl('M'))
      eq('GitSignsChange', review_hl('T'))
      eq('a "b".lua', review_status('M').filepath)
    end)
  end)
end)
