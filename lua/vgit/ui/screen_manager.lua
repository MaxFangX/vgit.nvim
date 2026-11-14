local loop = require('vgit.core.loop')
local scene_setting = require('vgit.settings.scene')
local DiffScreen = require('vgit.features.screens.DiffScreen')
local HistoryScreen = require('vgit.features.screens.HistoryScreen')
local LineBlameScreen = require('vgit.features.screens.LineBlameScreen')
local ProjectDiffScreen = require('vgit.features.screens.ProjectDiffScreen')
local ProjectLogsScreen = require('vgit.features.screens.ProjectLogsScreen')
local ProjectStashScreen = require('vgit.features.screens.ProjectStashScreen')
local ProjectCommitScreen = require('vgit.features.screens.ProjectCommitScreen')
local ProjectCommitsScreen = require('vgit.features.screens.ProjectCommitsScreen')
local ProjectReviewByFileScreen = require('vgit.features.screens.ProjectReviewByFileScreen')
local ProjectReviewByCommitScreen = require('vgit.features.screens.ProjectReviewByCommitScreen')

local screen_manager = {
  screens = {},
  active_screen = nil,
}

function screen_manager.dispatch_action(action_name, ...)
  if screen_manager.has_active_screen() and screen_manager.has_action(action_name) then
    screen_manager.active_screen[action_name](screen_manager.active_screen, ...)
  end
  return screen_manager
end

function screen_manager.screens.diff_screen(opts)
  local diff_screen = DiffScreen({ layout_type = scene_setting:get('diff_preference') })
  return diff_screen:create(opts), diff_screen
end

function screen_manager.screens.diff_hunk_screen(opts)
  local diff_hunk_screen = DiffScreen({ is_hunk = true, layout_type = scene_setting:get('diff_preference') })
  return diff_hunk_screen:create(opts), diff_hunk_screen
end

function screen_manager.screens.project_logs_screen(...)
  local project_logs_screen = ProjectLogsScreen()
  return project_logs_screen:create({ ... }), project_logs_screen
end

function screen_manager.screens.project_stash_screen(...)
  local project_stash_screen = ProjectStashScreen({ layout_type = scene_setting:get('diff_preference') })
  return project_stash_screen:create({ ... }), project_stash_screen
end

function screen_manager.screens.project_diff_screen()
  local project_diff_screen = ProjectDiffScreen({ layout_type = scene_setting:get('diff_preference') })
  return project_diff_screen:create(), project_diff_screen
end

function screen_manager.screens.project_commits_screen(...)
  local project_commits_screen = ProjectCommitsScreen({ layout_type = scene_setting:get('diff_preference') })
  return project_commits_screen:create({ ... }), project_commits_screen
end

function screen_manager.screens.history_screen()
  local history_screen = HistoryScreen({ layout_type = scene_setting:get('diff_preference') })
  return history_screen:create(), history_screen
end

function screen_manager.screens.commit_screen(...)
  local commit_screen = ProjectCommitScreen()
  return commit_screen:create(...), commit_screen
end

function screen_manager.screens.line_blame_screen()
  local line_blame_screen = LineBlameScreen({ layout_type = scene_setting:get('diff_preference') })
  return line_blame_screen:create(), line_blame_screen
end

-- A review screen of class `Screen`, or with `browse`, its browse of a range
local function review_screen(Screen, browse)
  return function(...)
    local screen = Screen({ layout_type = scene_setting:get('diff_preference'), browse = browse })
    return screen:create({ ... }), screen
  end
end

screen_manager.screens.project_review_by_file_screen = review_screen(ProjectReviewByFileScreen)
screen_manager.screens.project_review_by_commit_screen = review_screen(ProjectReviewByCommitScreen)
screen_manager.screens.project_browse_by_file_screen = review_screen(ProjectReviewByFileScreen, true)
screen_manager.screens.project_browse_by_commit_screen = review_screen(ProjectReviewByCommitScreen, true)

function screen_manager.is_screen_registered(screen_name)
  return type(screen_manager.screens[screen_name]) == 'function'
end

function screen_manager.has_action(action)
  return type(screen_manager.active_screen[action]) == 'function'
end

function screen_manager.has_active_screen()
  return screen_manager.active_screen ~= nil
end

function screen_manager.toggle_diff_preference()
  local diff_preference = scene_setting:get('diff_preference')

  if diff_preference == 'unified' then
    scene_setting:set('diff_preference', 'split')
  elseif diff_preference == 'split' then
    scene_setting:set('diff_preference', 'unified')
  end

  return screen_manager
end

function screen_manager.destroy_active_screen()
  local screen = screen_manager.active_screen
  if not screen then return screen_manager end

  -- destroy() can yield (free_textlock), letting queued BufWinLeave/QuitPre
  -- handlers re-enter, so clear the active screen first
  screen_manager.active_screen = nil
  screen:destroy()

  return screen_manager
end

function screen_manager.create(screen_name, ...)
  if not screen_manager.is_screen_registered(screen_name) then return screen_manager end
  if screen_manager.has_active_screen() then screen_manager.destroy_active_screen() end

  local success, screen = screen_manager.screens[screen_name](...)
  if success then
    screen_manager.active_screen = screen
    local scene = screen.scene
    scene
        :on('BufWinLeave', function()
          loop.free_textlock()
          if screen_manager.has_active_screen() then return screen_manager.destroy_active_screen() end
        end)
        :on('QuitPre', function()
          if screen_manager.has_active_screen() then return screen_manager.destroy_active_screen() end
        end)
    scene:set_keymap({
      {
        mode = 'n',
        key = scene_setting:get('keymaps').quit,
        handler = loop.coroutine(function()
          if screen.on_quit and screen:on_quit() then
            -- on_quit destroyed the screen itself, so clear it, or
            -- window-close autocmds would destroy (and re-save) it again
            if screen_manager.active_screen == screen then screen_manager.active_screen = nil end
            return
          end
          screen_manager.destroy_active_screen()
        end)
      }
    })
  end

  return screen_manager
end

return screen_manager
