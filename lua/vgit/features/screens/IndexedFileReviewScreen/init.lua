local StatusListView = require('vgit.ui.views.StatusListView')
local IndexedReviewScreen = require('vgit.features.screens.IndexedReviewScreen')
local Model = require('vgit.features.screens.IndexedFileReviewScreen.Model')
local setting = require('vgit.settings.indexed_file_review')

local IndexedFileReviewScreen = IndexedReviewScreen:extend()

function IndexedFileReviewScreen:constructor(opts)
  opts = opts or {}

  local base = IndexedReviewScreen.constructor(self, opts)
  base.name = 'Indexed File Review Screen'
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
      header = true,
      footer = false,
    },
  })

  IndexedReviewScreen.init_views(base, list_plot, diff_plot)

  return base
end

return IndexedFileReviewScreen
