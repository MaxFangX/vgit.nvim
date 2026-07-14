local dimensions = require('vgit.ui.dimensions')
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
