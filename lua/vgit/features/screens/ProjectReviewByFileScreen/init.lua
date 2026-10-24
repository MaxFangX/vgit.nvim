local dimensions = require('vgit.ui.dimensions')
local StatusListView = require('vgit.ui.views.StatusListView')
local ProjectReviewScreen = require('vgit.features.screens.ProjectReviewScreen')
local Model = require('vgit.features.screens.ProjectReviewByFileScreen.Model')
local setting = require('vgit.settings.project_review_by_file')

local ProjectReviewByFileScreen = ProjectReviewScreen:extend()

function ProjectReviewByFileScreen:constructor(opts)
  local base = ProjectReviewScreen.constructor(self)
  base.name = 'Project Review By File Screen'
  base.model = Model(opts)
  base.setting = setting

  -- Fixed layout: list on left, diff on right. The list column is a fixed
  -- character width (drag the boundary or set list_width to change it).
  local list_pct, diff_pct, list_cols = dimensions.fixed_split(setting:get('list_width'))
  local list_plot = { row = 1, width = list_pct }
  local diff_plot = { row = 1, col = list_pct, width = diff_pct }
  base.list_cols = list_cols

  base.list_view = StatusListView(base.scene, {
    entries = function()
      return base.model:get_entries()
    end,
  }, list_plot)

  ProjectReviewScreen.init_views(base, diff_plot)

  return base
end

return ProjectReviewByFileScreen
