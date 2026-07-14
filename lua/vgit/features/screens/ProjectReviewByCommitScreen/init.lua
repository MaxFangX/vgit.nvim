local dimensions = require('vgit.ui.dimensions')
local CommitListView = require('vgit.ui.views.CommitListView')
local CommitMessageView = require('vgit.ui.views.CommitMessageView')
local ProjectReviewScreen = require('vgit.features.screens.ProjectReviewScreen')
local Model = require('vgit.features.screens.ProjectReviewByCommitScreen.Model')
local setting = require('vgit.settings.project_review_by_commit')

local ProjectReviewByCommitScreen = ProjectReviewScreen:extend()

-- Height of commit message box
local MSG_HEIGHT = 14

function ProjectReviewByCommitScreen:constructor(opts)
  opts = opts or {}

  local base = ProjectReviewScreen.constructor(self, opts)
  base.name = 'Project Review By Commit Screen'
  base.model = Model(opts)
  base.setting = setting

  -- Configurable layout based on list_position setting. In left/right
  -- layouts the list column is a fixed list_width characters wide.
  local list_position = setting:get('list_position') or 'left'
  local list_pct, diff_pct = dimensions.fixed_split(setting:get('list_width'))
  local list_plot, diff_plot, msg_plot

  if list_position == 'right' then
    local list_height = string.format('%svh', 100 - MSG_HEIGHT)
    local msg_row = list_height
    list_plot = { row = 1, col = diff_pct, width = list_pct, height = list_height }
    msg_plot = { row = msg_row, col = diff_pct, width = list_pct, height = string.format('%svh', MSG_HEIGHT) }
    diff_plot = { row = 1, width = diff_pct }
  elseif list_position == 'top' then
    -- No commit message box for top/bottom layouts
    list_plot = { row = 1, height = '25vh', width = '100vw' }
    diff_plot = { row = '25vh', height = '75vh', width = '100vw' }
    msg_plot = nil
  elseif list_position == 'bottom' then
    list_plot = { row = '75vh', height = '25vh', width = '100vw' }
    diff_plot = { row = 1, height = '75vh', width = '100vw' }
    msg_plot = nil
  else
    -- 'left' (default): list takes remaining height after message box
    local list_height = string.format('%svh', 100 - MSG_HEIGHT)
    local msg_row = list_height
    list_plot = { row = 1, width = list_pct, height = list_height }
    msg_plot = { row = msg_row, width = list_pct, height = string.format('%svh', MSG_HEIGHT) }
    diff_plot = { row = 1, col = list_pct, width = diff_pct }
  end

  base.list_view = CommitListView(base.scene, {
    entries = function()
      return base.model:get_entries()
    end,
  }, list_plot, {
    elements = {
      header = true,
      footer = false,
    },
  })

  -- Create commit message view for left/right layouts
  if msg_plot then
    base.commit_message_view = CommitMessageView(base.scene, {
      message = function()
        local active = base.list_view:get_active_commit()
        if not active then return {} end
        return base.model:get_commit_message(active.hash) or {}
      end,
      list_view = function() return base.list_view end,
    }, msg_plot, {
      elements = {
        header = true,
        footer = false,
      },
      max_height = MSG_HEIGHT,
      min_height = 1,
    })
  end

  ProjectReviewScreen.init_views(base, list_plot, diff_plot)

  return base
end

return ProjectReviewByCommitScreen
