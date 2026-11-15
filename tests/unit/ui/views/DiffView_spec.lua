local Diff = require('vgit.core.Diff')
local Scene = require('vgit.ui.Scene')
local DiffView = require('vgit.ui.views.DiffView')
local git_hunks = require('vgit.git.git_hunks')
local scene_setting = require('vgit.settings.scene')

local eq = assert.are.same

local function sentence(subject, words)
  return string.rep(' ', 12) .. subject .. string.rep(' and then some more words', words)
end

-- Split rows, in panes too narrow for the long lines:
--   1 short          | short
--   2 long           | long
--   3 long           | longer still   (changed)
--   4 mid            | mid
--   5 (blank)        | long           (changed)
--   6 end            | end
--   7 _              | long           (added)
local OLD = { 'short', sentence('context', 4), sentence('a change', 4), 'mid', '', 'end' }
local NEW = {
  'short',
  sentence('context', 4),
  sentence('a changed line', 9),
  'mid',
  sentence('was blank', 5),
  'end',
  sentence('added', 6),
}
local CHANGED, BLANK, ADDED = 3, 5, 7
local UNWRAPPED = { 1, 1, 1, 1, 1, 1, 1 }

local function open(layout_type, new)
  local scene = Scene()
  local diff = Diff():generate(git_hunks.live(OLD, new or NEW), new or NEW, layout_type)
  local view = DiffView(scene, {
    layout_type = function() return layout_type end,
    filepath = function() return 'file.txt' end,
    filetype = function() return 'text' end,
    diff = function() return diff end,
  }, { row = 1 })
  view:define()
  view:mount()
  view:render()
  return view, scene
end

local function win_option(component, name)
  return vim.api.nvim_get_option_value(name, { win = component.window.win_id })
end

-- Screen rows of each buffer line of `component`
local function heights(component)
  local result = {}
  for row = 0, component:get_line_count() - 1 do
    result[#result + 1] = component:get_row_height(row)
  end
  return result
end

-- Texts overlaid on 1-based `lnum` of `component` by `kind` of extmark, in column order
local function overlays(component, kind, lnum)
  local ns_id = component.buffer[kind .. '_extmark'].ns_id
  local marks = vim.api.nvim_buf_get_extmarks(component.buffer.bufnr, ns_id, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })

  local result = {}
  for _, mark in ipairs(marks) do
    for _, chunk in ipairs(mark[4].virt_text or {}) do
      if chunk[2] then result[#result + 1] = chunk[1] end
    end
  end
  return result
end

describe('DiffView wrap:', function()
  local scene

  after_each(function()
    if scene then scene:destroy() end
    scene = nil
    scene_setting:set('diff_wrap', false)
  end)

  it('cuts long lines off until toggled, then wraps them', function()
    local view
    view, scene = open('split')
    local previous, current = unpack(view:get_components())
    eq({ false, false }, { win_option(previous, 'wrap'), win_option(current, 'wrap') })
    eq(UNWRAPPED, heights(current))

    view:toggle_wrap()
    eq({ true, true }, { win_option(previous, 'wrap'), win_option(current, 'wrap') })
    eq(true, scene_setting:get('diff_wrap'))
    assert.is_true(heights(current)[CHANGED] > 2)

    view:toggle_wrap()
    eq({ false, false }, { win_option(previous, 'wrap'), win_option(current, 'wrap') })
    eq(UNWRAPPED, heights(previous))
  end)

  it('keeps the rows of the split panes level', function()
    local view
    view, scene = open('split')
    local previous, current = unpack(view:get_components())
    view:toggle_wrap()

    -- Unpadded, the changed, blank and void rows are shorter on the left
    local padded = heights(current)
    eq(padded, heights(previous))
    previous:clear_extmark_paddings()
    local bare = heights(previous)
    for _, lnum in ipairs({ CHANGED, BLANK, ADDED }) do
      assert.is_true(bare[lnum] < padded[lnum], 'row ' .. lnum)
    end
    eq({ 1, 1 }, { bare[BLANK], bare[ADDED] })
  end)

  it('pads again for the next diff and for the wrap turned back on', function()
    local view
    view, scene = open('split')
    local previous, current = unpack(view:get_components())
    view:toggle_wrap()
    view:toggle_wrap()
    view:toggle_wrap()
    eq(heights(current), heights(previous))
    assert.is_true(heights(previous)[ADDED] > 1)

    -- The longer side is now the left one
    scene:destroy()
    view, scene = open('split', { 'short', sentence('context', 4), 'a change', 'mid', '', 'end' })
    previous, current = unpack(view:get_components())
    eq(true, win_option(current, 'wrap'))
    eq(heights(previous), heights(current))
    assert.is_true(heights(current)[CHANGED] > 1)
  end)

  it('highlights changed words where the wrapped line shows them', function()
    local view
    view, scene = open('split')
    local _, current = unpack(view:get_components())
    local line = NEW[CHANGED]

    -- Cut off: the whole line is overlaid, its changed words highlighted
    eq({}, overlays(current, 'highlight', CHANGED))
    local changed = table.concat(overlays(current, 'text', CHANGED))
    assert.is_true(changed ~= '')

    -- Wrapped: the same words, each overlaid at its own column
    view:toggle_wrap()
    eq({}, overlays(current, 'text', CHANGED))
    local words = overlays(current, 'highlight', CHANGED)
    eq(changed, table.concat(words))
    assert.is_true(#words > 1)

    local ns_id = current.buffer.highlight_extmark.ns_id
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(current.buffer.bufnr, ns_id, { CHANGED - 1, 0 }, { CHANGED - 1, -1 }, { details = true })) do
      local word = mark[4].virt_text[1][1]
      eq(word, line:sub(mark[3] + 1, mark[3] + #word))
    end
  end)

  it('wraps the unified pane, which needs no padding', function()
    local view
    view, scene = open('unified')
    local current = view:get_components()[1]
    view:toggle_wrap()

    eq(true, win_option(current, 'wrap'))
    assert.is_true(heights(current)[2] > 1)
    eq(0, #vim.api.nvim_buf_get_extmarks(current.buffer.bufnr, current.buffer.padding_extmark.ns_id, 0, -1, {}))
  end)
end)
