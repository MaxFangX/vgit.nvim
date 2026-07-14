local dimensions = require('vgit.ui.dimensions')
local StatusListView = require('vgit.ui.views.StatusListView')
local ProjectReviewScreen = require('vgit.features.screens.ProjectReviewScreen')
local Model = require('vgit.features.screens.ProjectReviewByFileScreen.Model')
local setting = require('vgit.settings.project_review_by_file')

local ProjectReviewByFileScreen = ProjectReviewScreen:extend()

function ProjectReviewByFileScreen:constructor(opts)
  opts = opts or {}

  local base = ProjectReviewScreen.constructor(self, opts)
  base.name = 'Project Review By File Screen'
  base.model = Model(opts)
  base.setting = setting

  -- Fixed layout: list on left (fixed list_width columns), diff on right
  local list_pct, diff_pct = dimensions.fixed_split(setting:get('list_width'))
  local list_plot = { row = 1, width = list_pct }
  local diff_plot = { row = 1, col = list_pct, width = diff_pct }

  base.list_view = StatusListView(base.scene, {
    entries = function()
      return base.model:get_entries()
    end,
  }, list_plot, {
    elements = {
      header = true,
      footer = false,
    },
  })

  ProjectReviewScreen.init_views(base, list_plot, diff_plot)

  return base
end

return ProjectReviewByFileScreen
