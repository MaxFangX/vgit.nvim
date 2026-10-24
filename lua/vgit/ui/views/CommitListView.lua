local BaseListView = require('vgit.ui.views.BaseListView')
local fold_tree = require('vgit.ui.fold_tree')
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
  -- The expanded commit, { hash, section } (nil: none)
  base.active_commit = nil
  return base
end

-- Expand commit `hash` in section `section` (nil: collapse all), re-render,
-- and tell props.on_active_commit. No-op if it is already the active one.
function CommitListView:set_active_commit(hash, section)
  local active = self.active_commit
  if active and active.hash == hash and active.section == section then return end
  if not active and not hash then return end

  self.active_commit = hash and { hash = hash, section = section } or nil
  self:render()
  if self.props.on_active_commit then self.props.on_active_commit() end
end

function CommitListView:get_active_commit()
  return self.active_commit
end

-- Expand the commit holding file `id`, then reveal the file
function CommitListView:reveal(id)
  local path = fold_tree.path_to(self.state.folds, id)
  if not path then return false end

  -- section > commit > folders > file
  local commit = path[2]
  self:set_active_commit(commit.commit_hash, commit.section_type)
  return BaseListView.reveal(self, id)
end

local function is_commit_row(item, hash, section)
  return item.node_type == 'commit' and item.commit_hash == hash and item.section_type == section
end

-- Enter on a commit row expands it (collapsing the open one) or collapses it,
-- keeping the cursor on it; other rows toggle as usual
function CommitListView:toggle_current_list_item()
  local item = self:get_current_list_item()
  if not item or item.node_type ~= 'commit' then return BaseListView.toggle_current_list_item(self) end

  local hash, section = item.commit_hash, item.section_type
  local active = self.active_commit
  if active and is_commit_row(item, active.hash, active.section) then
    self:set_active_commit(nil)
  else
    self:set_active_commit(hash, section)
  end
  self:move_to_item(function(node) return is_commit_row(node, hash, section) end)
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
  local index_width, id_width = column_widths(entries)
  local index_format = string.format('%%0%dd', index_width)
  local row_format = string.format('%%s - %%-%ds - %%s', id_width)
  local active = self.active_commit

  local folds = {}
  for _, section in ipairs(entries) do
    local commit_items = {}

    for _, commit_data in ipairs(section.commits or {}) do
      local commit = commit_data.commit
      local index_label = string.format(index_format, commit_data.index)
      commit_items[#commit_items + 1] = {
        node_type = 'commit',
        open = active ~= nil and active.hash == commit.hash and active.section == section.type,
        value = string.format(row_format, index_label, commit.change_id_short or commit.short_hash, commit.message),
        items = StatusFolds():generate(commit_data.files),
        section_type = section.type,
        commit_hash = commit.hash,
        icon_before = function(item)
          return { icon = item.open and '' or '' }
        end,
      }
    end

    folds[#folds + 1] = {
      node_type = 'section',
      open = true,
      value = section.title,
      items = commit_items,
      section_type = section.type,
    }
  end

  self:sync_folds(folds)
end

return CommitListView
