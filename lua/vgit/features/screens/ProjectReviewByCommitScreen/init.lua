local dimensions = require('vgit.ui.dimensions')
local CommitListView = require('vgit.ui.views.CommitListView')
local CommitMessageView = require('vgit.ui.views.CommitMessageView')
local ProjectReviewScreen = require('vgit.features.screens.ProjectReviewScreen')
local Model = require('vgit.features.screens.ProjectReviewByCommitScreen.Model')
local setting = require('vgit.settings.project_review_by_commit')
local file_navigation = require('vgit.features.screens.file_navigation')

local ProjectReviewByCommitScreen = ProjectReviewScreen:extend()

-- Initial height of the commit message box (vh), after which it fits its
-- message
local MSG_HEIGHT = 14

-- Narrowest list column in left/right layouts, so the message box below it
-- fits 72-column commit bodies without wrapping
local MIN_LIST_WIDTH = 72

-- Plots for the list, the commit message box and the diff. Left/right
-- layouts get a `cols`-wide list column with the message box below it. In
-- left layout the boundary is draggable, so the clamped width is returned as
-- list_cols. Top/bottom layouts have no message box.
local function plots_for(position, cols)
  if position == 'top' then
    return { row = 1, height = '25vh', width = '100vw' }, nil, { row = '25vh', height = '75vh', width = '100vw' }
  end
  if position == 'bottom' then
    return { row = '75vh', height = '25vh', width = '100vw' }, nil, { row = 1, height = '75vh', width = '100vw' }
  end

  local list_pct, diff_pct, list_cols = dimensions.fixed_split(cols)
  local is_left = position ~= 'right'
  local list_col = not is_left and diff_pct or nil
  local list_height = dimensions.vh(100 - MSG_HEIGHT)
  local list_plot = { row = 1, col = list_col, width = list_pct, height = list_height }
  local msg_plot = { row = list_height, col = list_col, width = list_pct, height = dimensions.vh(MSG_HEIGHT) }
  local diff_plot = { row = 1, col = is_left and list_pct or nil, width = diff_pct }
  return list_plot, msg_plot, diff_plot, is_left and list_cols or nil
end

function ProjectReviewByCommitScreen:constructor(opts)
  local base = ProjectReviewScreen.constructor(self)
  base.name = 'Project Review By Commit Screen'
  base.model = Model(opts)
  base.setting = setting

  base.list_view = CommitListView(base.scene, {
    entries = function()
      return base.model:get_entries()
    end,
    on_active_commit = function()
      if base.commit_message_view then base.commit_message_view:render() end
    end,
  })

  -- Left/right layouts have a message box under the list
  local position = setting:get('list_position')
  if position ~= 'top' and position ~= 'bottom' then
    base.commit_message_view = CommitMessageView(base.scene, {
      message = function()
        local active = base.list_view:get_active_commit()
        return active and base.model:get_commit_message(active.hash) or {}
      end,
      -- End the list above the box. Its body starts a few rows down (app
      -- bar, header).
      on_resize = function(row)
        local window = base.scene:get('list').window
        if window:is_valid() then window:set_height(math.max(1, row - window:get_win_plot().row)) end
      end,
    })
  end

  ProjectReviewScreen.init_views(base)

  return base
end

-- J/K in the list: the next commit's first file, or the previous commit's
-- last file, wherever the cursor sits in the current commit. From a section
-- header, J lands on the section's first commit. Wraps.
function ProjectReviewByCommitScreen:jump_section(direction)
  local from = self.list_view:cursor_file_index()
  if not from then return end

  local files = self.list_view:file_nodes()
  local target = from
  local on_section = self.list_view:get_current_list_item().node_type == 'section'
  if not (on_section and direction == 'next') then
    target = file_navigation.adjacent_commit_target(files, from, direction)
  end
  self:select_file(files, from, target, direction)
end

-- Without `cols`, the list column is list_width if set (user config, or a
-- drag earlier this session), else (auto, the default) the widest commit
-- row, clamped to [MIN_LIST_WIDTH, 45% of the editor]. The cap truncates an
-- over-long commit subject rather than squeezing the diff.
function ProjectReviewByCommitScreen:plot_views(cols)
  cols = cols or setting:get('list_width')
  if cols <= 0 then
    local cap = math.floor(dimensions.global_width() * 0.45)
    cols = math.min(math.max(self.list_view:max_row_width(), MIN_LIST_WIDTH), cap)
  end

  local list_plot, msg_plot, diff_plot, list_cols = plots_for(setting:get('list_position'), cols)
  self.list_view.plot, self.diff_view.plot, self.list_cols = list_plot, diff_plot, list_cols
  if self.commit_message_view then self.commit_message_view.plot = msg_plot end
end

return ProjectReviewByCommitScreen
