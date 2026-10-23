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

-- Column widths shared by every commit row, so the same commit aligns across
-- the Seen/Unseen sections: the widest stable `index` (set by the model, min
-- 2 digits) and the widest displayed id (jj change id in jj repos, git short
-- hash otherwise; either can vary in length).
local function column_widths(entries)
  local max_index = 0
  local id_width = 0
  for _, section in ipairs(entries) do
    for _, commit_data in ipairs(section.commits or {}) do
      max_index = math.max(max_index, commit_data.index or 0)
      local commit = commit_data.commit
      id_width = math.max(id_width, #(commit.change_id_short or commit.short_hash))
    end
  end
  return math.max(2, #tostring(max_index)), id_width
end

-- Cells rendered before a commit row's text: indent + fold symbol + space +
-- expansion icon + space (see FoldableListComponent fold headers).
local ROW_DECORATION_WIDTH = 6

-- Width in cells of the widest commit row as rendered ('NN - id - message'
-- plus fold decoration), for auto-sizing the list column.
function CommitListView:max_row_width()
  local entries = self.props.entries()
  local index_width, id_width = column_widths(entries)

  local message_width = 0
  for _, section in ipairs(entries) do
    for _, commit_data in ipairs(section.commits or {}) do
      message_width = math.max(message_width, #commit_data.commit.message)
    end
  end

  return ROW_DECORATION_WIDTH + index_width + 3 + id_width + 3 + message_width
end

function CommitListView:render()
  local entries = self.props.entries()
  local open = self.config.open_folds
  if open == nil then open = true end

  local index_width, id_width = column_widths(entries)
  local index_format = string.format('%%0%dd', index_width)
  local row_format = string.format('%%s - %%-%ds - %%s', id_width)

  local folds = {}
  for _, section in ipairs(entries) do
    local commit_items = {}

    for _, commit_data in ipairs(section.commits or {}) do
      local commit = commit_data.commit
      local file_items = StatusFolds():generate(commit_data.files)
      mark_items(file_items, section.title, commit.hash)

      local index_label = string.format(index_format, commit_data.index)
      local is_active = self.active_commit
        and self.active_commit.hash == commit.hash
        and self.active_commit.section == section.title
      commit_items[#commit_items + 1] = {
        open = is_active,
        value = string.format(row_format, index_label, commit.change_id_short or commit.short_hash, commit.message),
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
