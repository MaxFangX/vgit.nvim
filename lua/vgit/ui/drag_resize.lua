--[[
  Mouse-draggable vertical boundary between two columns of floating windows.

  attach() installs global normal-mode <LeftMouse>/<LeftDrag>/<LeftRelease>
  mappings for the lifetime of a screen. A press on the 2-column grab zone at
  the boundary starts a drag; any other click falls through to the default
  mouse behavior. The handlers are expr mappings (they only read the mouse
  position), so the actual window reconfiguration is vim.schedule'd out of
  the expr context.

  opts:
    boundary()          -> current boundary column: 1-based screen column of
                           the first column right of the divide
    on_drag(boundary)   -> move the divide so the boundary sits at `boundary`
                           (should be cheap: window re-plots only)
    on_release()        -> finalize (re-render width-dependent content)

  Returns detach(), which removes the mappings and restores any they shadowed.
]]

local drag_resize = {}

local KEYS = { '<LeftMouse>', '<LeftDrag>', '<LeftRelease>' }

function drag_resize.attach(opts)
  local dragging = false
  -- Offset between the boundary and the pressed column, so the divide keeps
  -- its position relative to the pointer instead of jumping on the first
  -- drag event.
  local grab_offset = 0

  local shadowed = {}
  for _, lhs in ipairs(KEYS) do
    local existing = vim.fn.maparg(lhs, 'n', false, true)
    if existing and existing.lhs then shadowed[lhs] = existing end
  end

  vim.keymap.set('n', '<LeftMouse>', function()
    local col = vim.fn.getmousepos().screencol
    local boundary = opts.boundary()
    if col == boundary or col == boundary - 1 then
      dragging = true
      grab_offset = boundary - col
      return ''
    end
    return '<LeftMouse>'
  end, { expr = true, desc = 'VGit: grab column boundary' })

  vim.keymap.set('n', '<LeftDrag>', function()
    if not dragging then return '<LeftDrag>' end
    local col = vim.fn.getmousepos().screencol
    vim.schedule(function()
      opts.on_drag(col + grab_offset)
    end)
    return ''
  end, { expr = true, desc = 'VGit: drag column boundary' })

  vim.keymap.set('n', '<LeftRelease>', function()
    if not dragging then return '<LeftRelease>' end
    dragging = false
    vim.schedule(function()
      opts.on_release()
    end)
    return ''
  end, { expr = true, desc = 'VGit: release column boundary' })

  return function()
    for _, lhs in ipairs(KEYS) do
      pcall(vim.keymap.del, 'n', lhs)
      if shadowed[lhs] then vim.fn.mapset('n', false, shadowed[lhs]) end
    end
  end
end

return drag_resize
