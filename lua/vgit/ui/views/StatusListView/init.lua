local BaseListView = require('vgit.ui.views.BaseListView')
local StatusFolds = require('vgit.ui.views.StatusListView.StatusFolds')

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

return StatusListView
