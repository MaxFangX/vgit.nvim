local loop = require('vgit.core.loop')
local utils = require('vgit.core.utils')
local Object = require('vgit.core.Object')
local dimensions = require('vgit.ui.dimensions')
local fold_tree = require('vgit.ui.fold_tree')
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

-- Put the cursor on the first row matching pred(item, lnum); returns the item
function BaseListView:move_to_item(pred)
  local item, lnum = self:find_list_item(pred)
  if item then self:set_lnum(lnum) end
  return item
end

-- Move to the first file row whose status matches callback(status, type, lnum)
function BaseListView:move_to(callback)
  local item = self:move_to_item(function(node, lnum)
    local status = node.entry and node.entry.status
    return status ~= nil and callback(status, node.entry.type, lnum) == true
  end)
  return item and item.entry.status
end

-- Like move_to but passes the full entry (with commit_hash, etc.)
function BaseListView:move_to_entry(callback)
  local item = self:move_to_item(function(node)
    return node.entry ~= nil and node.entry.status ~= nil and callback(node.entry) == true
  end)
  return item and item.entry
end

function BaseListView:set_lnum(lnum)
  self.scene:get('list'):unlock():set_lnum(lnum):lock()
end

-- Scroll the list to its 'top' or 'bottom' edge
function BaseListView:scroll_to(edge)
  self.scene:get('list'):call(function()
    local topline = 1
    if edge == 'bottom' then topline = math.max(1, vim.fn.line('$') - vim.fn.winheight(0) + 1) end
    vim.fn.winrestview({ topline = topline })
  end)
end

-- File nodes in display order, collapsed folds included. Cached per folds
-- tree: every render builds a new one.
function BaseListView:file_nodes()
  local folds = self.state.folds
  if self._file_nodes_of ~= folds then
    self._file_nodes = fold_tree.file_nodes(folds)
    self._file_nodes_of = folds
  end
  return self._file_nodes
end

-- Index into file_nodes() of the cursor row's file: the row itself, or the
-- first file under a header row (then on_header is true)
function BaseListView:cursor_file_index()
  local item = self:get_current_list_item()
  local file = item and fold_tree.first_file(item)
  if not file then return nil end

  for i, node in ipairs(self:file_nodes()) do
    if node == file then return i, item ~= file end
  end
end

-- Open the folds above file node `id` and put the cursor on it. Returns
-- false when there is no such node.
function BaseListView:reveal(id)
  local path = fold_tree.path_to(self.state.folds, id)
  if not path then return false end

  local opened = false
  for i = 1, #path - 1 do
    if not path[i].open then
      path[i].open = true
      opened = true
    end
  end
  if opened then self:sync() end

  local file = path[#path]
  return self:move_to_item(function(item) return item == file end) ~= nil
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

  self:set_lnum(lnum)
  return self:get_list_item(lnum)
end

function BaseListView:toggle_current_list_item()
  local lnum = self.scene:get('list'):get_lnum()
  local item = self:get_list_item(lnum)

  if item and item.open ~= nil then item.open = not item.open end
  self:sync()
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

-- Draw state.folds, e.g. after opening or closing folds
function BaseListView:sync()
  self.scene:get('list'):unlock():set_title(self.state.title):set_list(self.state.folds):sync():lock()
end

function BaseListView:sync_folds(folds)
  self.state.folds = folds
  self:sync()
end

return BaseListView
