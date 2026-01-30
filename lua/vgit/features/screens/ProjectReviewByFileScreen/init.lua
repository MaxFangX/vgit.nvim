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

  -- Fixed layout: list on left, diff on right
  local list_plot = { row = 1, width = '25vw' }
  local diff_plot = { row = 1, col = '25vw', width = '75vw' }

  base.list_view = StatusListView(base.scene, {
    entries = function()
      return base.model:get_entries()
    end,
  }, list_plot, {
    elements = {
      header = false,
      footer = false,
    },
  })

  ProjectReviewScreen.init_views(base, list_plot, diff_plot)

  return base
end

return ProjectReviewByFileScreen
