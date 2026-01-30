local BaseListView = require('vgit.ui.views.BaseListView')
local StatusFolds = require('vgit.ui.views.StatusListView.StatusFolds')

--[[
  CommitListView renders a hierarchical list:
    ▼ Unseen
      ▼ abc123 - commit message
        ▼ lua/
          file1.lua
          file2.lua
      ▼ def456 - commit message
        file3.lua
    ▼ Seen
      ...

  Each section (Unseen/Seen) contains commits, and each commit contains files.
]]

local CommitListView = BaseListView:extend()

function CommitListView:render()
  local entries = self.props.entries()

  local open = true
  local open_folds = self.config.open_folds
  if open_folds ~= nil then
    open = open_folds
  end

  local folds = {}
  for _, section in ipairs(entries) do
    -- Section level (Unseen/Seen)
    local commit_items = {}

    for _, commit_data in ipairs(section.commits or {}) do
      local commit = commit_data.commit
      local files = commit_data.files

      -- Build file tree for this commit using StatusFolds
      local file_items = StatusFolds():generate(files)

      -- Commit node
      commit_items[#commit_items + 1] = {
        open = open,
        value = string.format('%s - %s', commit.short_hash, commit.message),
        items = file_items,
        icon_before = function(item)
          return { icon = item.open and '' or '' }
        end,
      }
    end

    folds[#folds + 1] = {
      open = open,
      value = section.title,
      items = commit_items,
    }
  end

  self:sync_folds(folds)
end

return CommitListView
