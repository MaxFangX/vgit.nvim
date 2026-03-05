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

  Commits are collapsed by default and expand dynamically when the cursor
  enters them (via navigation or clicking).
]]

local CommitListView = BaseListView:extend()

function CommitListView:constructor(scene, props, plot, config)
  local base = BaseListView.constructor(self, scene, props, plot, config)
  -- Track which commit is currently expanded (hash + section, nil = none)
  base.active_commit = nil  -- { hash, section }
  return base
end

-- Set which commit should be expanded (nil to collapse all)
function CommitListView:set_active_commit(hash, section)
  if hash == nil then
    if self.active_commit == nil then return false end
    self.active_commit = nil
    return true
  end
  if self.active_commit and self.active_commit.hash == hash and self.active_commit.section == section then
    return false
  end
  self.active_commit = { hash = hash, section = section }
  return true
end

-- Get the currently active commit
function CommitListView:get_active_commit()
  return self.active_commit
end

-- Get entries data for navigation purposes
function CommitListView:get_entries()
  return self.props.entries()
end

-- Mark items with their section and commit info for tracking
local function mark_items(items, section_type, commit_hash)
  for _, item in ipairs(items) do
    item.section_type = section_type
    item.commit_hash = commit_hash
    if item.items then
      mark_items(item.items, section_type, commit_hash)
    end
  end
end

function CommitListView:render()
  local entries = self.props.entries()
  local open = self.config.open_folds
  if open == nil then open = true end

  local folds = {}
  for _, section in ipairs(entries) do
    local commit_items = {}

    for _, commit_data in ipairs(section.commits or {}) do
      local commit = commit_data.commit
      local file_items = StatusFolds():generate(commit_data.files)
      mark_items(file_items, section.title, commit.hash)

      local is_active = self.active_commit
        and self.active_commit.hash == commit.hash
        and self.active_commit.section == section.title
      commit_items[#commit_items + 1] = {
        open = is_active,
        value = string.format('%s - %s', commit.short_hash, commit.message),
        items = file_items,
        section_type = section.title,
        commit_hash = commit.hash,
        icon_before = function(item)
          return { icon = item.open and '' or '' }
        end,
      }
    end

    folds[#folds + 1] = {
      open = open,
      value = section.title,
      items = commit_items,
      section_type = section.title,
    }
  end

  self:sync_folds(folds)
end

return CommitListView
