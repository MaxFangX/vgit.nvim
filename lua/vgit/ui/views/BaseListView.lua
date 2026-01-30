local loop = require('vgit.core.loop')
local utils = require('vgit.core.utils')
local Object = require('vgit.core.Object')
local dimensions = require('vgit.ui.dimensions')
local FoldableListComponent = require('vgit.ui.components.FoldableListComponent')

--[[
  BaseListView provides the shared functionality for list views that display
  hierarchical, foldable content (StatusListView, CommitListView, etc.).

  Subclasses must implement:
    - render() - builds and sets the fold structure
]]

local BaseListView = Object:extend()

function BaseListView:constructor(scene, props, plot, config)
  return {
    plot = plot,
    scene = scene,
    props = props,
    state = {
      title = '',
      folds = nil,
    },
    config = config or {},
    event_handlers = {
      on_enter = function() end,
      on_move = function() end,
    },
  }
end

function BaseListView:get_components()
  return { self.scene:get('list') }
end

function BaseListView:define()
  self.scene:set(
    'list',
    FoldableListComponent({
      config = {
        elements = utils.object.assign({
          header = true,
          footer = false,
        }, self.config.elements),
        win_plot = dimensions.relative_win_plot(self.plot, {
          height = '100vh',
          width = '100vw',
        }),
        win_options = {
          cursorline = true,
        },
      },
    })
  )
end

function BaseListView:set_keymap(configs)
  utils.list.each(configs, function(config)
    self.scene:get('list'):set_keymap(config, config.handler)
  end)
end

function BaseListView:set_title(text)
  self.state.title = text
end

function BaseListView:get_list_item(lnum)
  return self.scene:get('list'):get_list_item(lnum)
end

function BaseListView:find_list_item(callback)
  return self.scene:get('list'):find_list_item(callback)
end

function BaseListView:each_list_item(callback)
  local component = self.scene:get('list')
  component:each_list_item(callback)
end

function BaseListView:find_status(callback)
  return self:find_list_item(function(node, lnum)
    local status = node.entry and node.entry.status or nil
    if not status then return false end
    local entry_type = node.entry.type
    return callback(status, entry_type, lnum) == true
  end)
end

-- Like find_status but passes the full entry (with commit_hash, etc.)
function BaseListView:find_entry(callback)
  return self:find_list_item(function(node, lnum)
    local entry = node.entry
    if not entry or not entry.status then return false end
    return callback(entry, lnum) == true
  end)
end

function BaseListView:each_status(callback)
  local component = self.scene:get('list')
  component:each_list_item(function(node, lnum)
    local status = node.entry and node.entry.status or nil
    if not status then return false end
    local entry_type = node.entry.type
    callback(status, entry_type, lnum)
  end)
end

function BaseListView:move_to(callback)
  local component = self.scene:get('list')
  local status, lnum = self:find_status(callback)
  if not status then return end

  loop.free_textlock()
  component:unlock():set_lnum(lnum):lock()
  return status
end

-- Like move_to but uses find_entry (passes full entry to callback)
function BaseListView:move_to_entry(callback)
  local component = self.scene:get('list')
  local entry, lnum = self:find_entry(callback)
  if not entry then return nil end

  loop.free_textlock()
  component:unlock():set_lnum(lnum):lock()
  return entry
end

function BaseListView:get_current_list_item()
  local component = self.scene:get('list')
  local lnum = component:get_lnum()
  return self:get_list_item(lnum)
end

function BaseListView:move(direction)
  local component = self.scene:get('list')
  local lnum = component:get_lnum()
  local count = component:get_line_count()

  if direction == 'down' then lnum = lnum + 1 end
  if direction == 'up' then lnum = lnum - 1 end

  -- Only wrap when navigating (direction specified), not when cursor is programmatically set
  if direction then
    if lnum < 1 then
      lnum = count
    elseif lnum > count then
      lnum = 1
    end
  else
    -- Clamp to valid range without wrapping
    if lnum < 1 then lnum = 1 end
    if lnum > count then lnum = count end
  end

  loop.free_textlock()
  component:unlock():set_lnum(lnum):lock()
  return self:get_list_item(lnum)
end

function BaseListView:toggle_current_list_item()
  local lnum = self.scene:get('list'):get_lnum()
  local item = self:get_list_item(lnum)

  if item and item.open ~= nil then item.open = not item.open end

  local component = self.scene:get('list')
  component:unlock():set_title(self.state.title):set_list(self.state.folds):sync():lock()
end

function BaseListView:mount(opts)
  local component = self.scene:get('list')
  component:mount(opts)

  if opts.event_handlers then
    self.event_handlers = utils.object.assign(self.event_handlers, opts.event_handlers)
  end

  self:set_keymap({
    {
      mode = 'n',
      key = '<enter>',
      desc = 'Enter item',
      handler = loop.coroutine(function()
        local item = self:get_current_list_item()
        if not item then return end
        self:toggle_current_list_item()
        self.event_handlers.on_enter(item)
      end),
    },
  })

  component:on('CursorMoved', function()
    local item = self:move()
    self.event_handlers.on_move(item)
  end)
end

-- Subclasses must override this method
function BaseListView:render()
  error('BaseListView:render() must be implemented by subclass')
end

-- Helper to sync folds to the component
function BaseListView:sync_folds(folds)
  self.state.folds = folds
  local component = self.scene:get('list')
  component:unlock():set_title(self.state.title):set_list(folds):sync():lock()
end

return BaseListView
