local BaseListView = require('vgit.ui.views.BaseListView')
local StatusFolds = require('vgit.ui.views.StatusListView.StatusFolds')
local section_headings = require('vgit.ui.views.StatusListView.section_headings')

local StatusListView = BaseListView:extend()

function StatusListView:render()
  local entries = self.props.entries()

  local open = true
  local open_folds = self.config.open_folds
  if open_folds ~= nil then
    open = open_folds
  end

  local folds = {}
  for _, entry in ipairs(entries) do
    folds[#folds + 1] = {
      open = open,
      value = entry.title,
      metadata = entry.metadata,
      items = StatusFolds(entry.metadata):generate(entry.entries),
    }
  end

  self:sync_folds(folds)
end

-- Move the cursor to the next/prev folder heading (see section_headings),
-- wrapping. Returns its item.
function StatusListView:jump_to_heading(direction)
  local component = self.scene:get('list')
  local current_lnum = component:get_lnum()
  local count = component:get_line_count()
  local delta = direction == 'next' and 1 or -1
  local headings = section_headings(self.state.folds)

  for offset = 1, count do
    local lnum = ((current_lnum - 1 + offset * delta) % count) + 1
    local item = self:get_list_item(lnum)
    if headings[item] then
      self:set_lnum(lnum)
      return item
    end
  end
end

return StatusListView
