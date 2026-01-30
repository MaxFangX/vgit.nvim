local CommitListView = require('vgit.ui.views.CommitListView')
local ProjectReviewScreen = require('vgit.features.screens.ProjectReviewScreen')
local Model = require('vgit.features.screens.ProjectReviewByCommitScreen.Model')
local setting = require('vgit.settings.project_review_by_commit')

local ProjectReviewByCommitScreen = ProjectReviewScreen:extend()

function ProjectReviewByCommitScreen:constructor(opts)
  opts = opts or {}

  local base = ProjectReviewScreen.constructor(self, opts)
  base.name = 'Project Review By Commit Screen'
  base.model = Model(opts)
  base.setting = setting

  -- Configurable layout based on list_position setting
  local list_position = setting:get('list_position') or 'left'
  local list_plot, diff_plot

  if list_position == 'left' then
    list_plot = { row = 1, width = '25vw' }
    diff_plot = { row = 1, col = '25vw', width = '75vw' }
  elseif list_position == 'right' then
    list_plot = { row = 1, col = '75vw', width = '25vw' }
    diff_plot = { row = 1, width = '75vw' }
  elseif list_position == 'top' then
    list_plot = { row = 1, height = '25vh', width = '100vw' }
    diff_plot = { row = '25vh', height = '75vh', width = '100vw' }
  elseif list_position == 'bottom' then
    list_plot = { row = '75vh', height = '25vh', width = '100vw' }
    diff_plot = { row = 1, height = '75vh', width = '100vw' }
  else
    list_plot = { row = 1, width = '25vw' }
    diff_plot = { row = 1, col = '25vw', width = '75vw' }
  end

  base.list_view = CommitListView(base.scene, {
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

return ProjectReviewByCommitScreen
