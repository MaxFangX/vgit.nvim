local dimensions = require('vgit.ui.dimensions')
local CommitListView = require('vgit.ui.views.CommitListView')
local CommitMessageView = require('vgit.ui.views.CommitMessageView')
local ProjectReviewScreen = require('vgit.features.screens.ProjectReviewScreen')
local Model = require('vgit.features.screens.ProjectReviewByCommitScreen.Model')
local setting = require('vgit.settings.project_review_by_commit')
local file_navigation = require('vgit.features.screens.file_navigation')

local ProjectReviewByCommitScreen = ProjectReviewScreen:extend()

-- Initial height of the commit message box (vh); it then fits its message
local MSG_HEIGHT = 14

-- Narrowest list column in left/right layouts: the message box below it
-- shows convention-wrapped (72-column) commit bodies unwrapped
local MIN_LIST_WIDTH = 72

-- Plots for the list, the commit message box and the diff. Left/right
-- layouts get a `cols`-wide list column with the message box below it, and
-- in left layout the boundary is draggable: list_cols, the clamped width.
-- Top/bottom layouts have no message box.
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

  -- With list_width = 0 (auto), the plots start at the floor width and
  -- resolve_list_width re-plots them once the commits are known
  local list_width = setting:get('list_width')
  local list_plot, msg_plot, diff_plot, list_cols =
    plots_for(setting:get('list_position'), list_width > 0 and list_width or MIN_LIST_WIDTH)
  base.list_cols = list_cols

  base.list_view = CommitListView(base.scene, {
    entries = function()
      return base.model:get_entries()
    end,
    on_active_commit = function()
      if base.commit_message_view then base.commit_message_view:render() end
    end,
  }, list_plot)

  if msg_plot then
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
    }, msg_plot)
  end

  ProjectReviewScreen.init_views(base, diff_plot)

  return base
end

-- J/K in the list: the next commit's first file, or the previous commit's
-- last file, wherever the cursor sits in the current commit. Wraps.
function ProjectReviewByCommitScreen:jump_section(direction)
  local from = self.list_view:cursor_file_index()
  if not from then return end

  local files = self.list_view:file_nodes()
  self:select_file(files, from, file_navigation.adjacent_commit_target(files, from, direction), direction)
end

-- Auto-size the list column to the widest commit row when list_width is
-- auto (0, the default), clamped to [MIN_LIST_WIDTH, 45% of the editor]. The
-- cap keeps one over-long commit subject from squeezing the diff (subjects
-- past it truncate). A positive list_width (user config, or a boundary drag
-- earlier this session) is used as-is. Called after fetch, before windows
-- are defined.
function ProjectReviewByCommitScreen:resolve_list_width()
  -- Top/bottom layouts (no message box) span the full width
  if not self.commit_message_view or setting:get('list_width') > 0 then return end

  local cap = math.floor(dimensions.global_width() * 0.45)
  local cols = math.min(math.max(self.list_view:max_row_width(), MIN_LIST_WIDTH), cap)
  local list_plot, msg_plot, diff_plot, list_cols = plots_for(setting:get('list_position'), cols)
  self.list_view.plot, self.commit_message_view.plot, self.diff_view.plot = list_plot, msg_plot, diff_plot
  self.list_cols = list_cols
end

function ProjectReviewByCommitScreen:apply_list_width(cols)
  if not ProjectReviewScreen.apply_list_width(self, cols) then return end

  -- Later CommitMessageView:resize calls re-derive geometry from the plot
  self.commit_message_view.plot.width = self.list_cols
  self:replot_column('commit_message', 0, self.list_cols)
end

function ProjectReviewByCommitScreen:finish_list_resize()
  ProjectReviewScreen.finish_list_resize(self)
  self.commit_message_view:render()
end

return ProjectReviewByCommitScreen
