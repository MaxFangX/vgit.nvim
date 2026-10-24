local icons = {}

-- nvim-web-devicons, or false when it isn't installed. Required once: a
-- failing require costs ~80 us, paid per list row.
local web_devicons

function icons.get(fname, extension)
  if web_devicons == nil then
    local ok, module = pcall(require, 'nvim-web-devicons')
    web_devicons = ok and module or false
  end
  if not web_devicons or not web_devicons.has_loaded() then return nil, '' end
  return web_devicons.get_icon(fname, extension)
end

return icons
