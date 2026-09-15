local dimensions = require('vgit.ui.dimensions')
local CommitListView = require('vgit.ui.views.CommitListView')
local CommitMessageView = require('vgit.ui.views.CommitMessageView')
local IndexedReviewScreen = require('vgit.features.screens.IndexedReviewScreen')
local Model = require('vgit.features.screens.IndexedCommitReviewScreen.Model')
local setting = require('vgit.settings.indexed_commit_review')

local IndexedCommitReviewScreen = IndexedReviewScreen:extend()

-- Height of commit message box
local MSG_HEIGHT = 14

function IndexedCommitReviewScreen:constructor(opts)
  opts = opts or {}

  local base = IndexedReviewScreen.constructor(self, opts)
  base.name = 'Indexed Commit Review Screen'
  base.model = Model(opts)
  base.setting = setting

  -- Configurable layout based on list_position setting. In left/right
  -- layouts the list column is a fixed character width (drag the boundary
  -- in left layout or set list_width to change it). With list_width = 0
  -- (auto) the plots are built at the floor width here and re-resolved by
  -- resolve_list_width() once commits are known.
  local list_position = setting:get('list_position') or 'left'
  local list_width = setting:get('list_width')
  if list_width <= 0 then list_width = 72 end
  local list_pct, diff_pct, list_cols = dimensions.fixed_split(list_width)
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
    -- Boundary dragging is only wired up for the left layout
    base.list_cols = list_cols
  end

  if list_position == 'left' or list_position == 'right' then
    base._width_plots = { position = list_position, list = list_plot, msg = msg_plot, diff = diff_plot }
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

  IndexedReviewScreen.init_views(base, list_plot, diff_plot)

  return base
end

-- Auto-size the list column to the widest commit row when list_width is
-- auto (0, the default), clamped to [72, 45% of the editor]. The floor
-- keeps convention-wrapped commit message bodies unwrapped in the message
-- box; the cap keeps one over-long commit subject from squeezing the diff
-- (subjects past it truncate). A positive list_width (user config, or a
-- boundary drag earlier this session) is used as-is. Called by the base
-- screen after fetch, before windows are defined.
function IndexedCommitReviewScreen:resolve_list_width()
  local plots = self._width_plots
  if not plots then return end
  if setting:get('list_width') > 0 then return end

  local cap = math.floor(dimensions.global_width() * 0.45)
  local cols = math.min(math.max(self.list_view:max_row_width(), 72), cap)
  local list_pct, diff_pct, list_cols = dimensions.fixed_split(cols)

  plots.list.width = list_pct
  if plots.msg then plots.msg.width = list_pct end
  plots.diff.width = diff_pct
  if plots.position == 'left' then
    plots.diff.col = list_pct
    self.list_cols = list_cols
  else
    plots.list.col = diff_pct
    if plots.msg then plots.msg.col = diff_pct end
  end
end

return IndexedCommitReviewScreen
