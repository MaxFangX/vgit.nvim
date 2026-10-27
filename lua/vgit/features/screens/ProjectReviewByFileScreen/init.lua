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

  base.list_view = StatusListView(base.scene, {
    entries = function()
      return base.model:get_entries()
    end,
  })

  ProjectReviewScreen.init_views(base)

  return base
end

-- List on the left, a fixed `cols` wide (list_width without cols; drag the
-- boundary to change it), diff on the right
function ProjectReviewByFileScreen:plot_views(cols)
  local list_pct, diff_pct, list_cols = dimensions.fixed_split(cols or setting:get('list_width'))
  self.list_view.plot = { row = 1, width = list_pct }
  self.diff_view.plot = { row = 1, col = list_pct, width = diff_pct }
  self.list_cols = list_cols
end

return ProjectReviewByFileScreen
