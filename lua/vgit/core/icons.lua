local icons = {}

-- nvim-web-devicons, or false when it isn't installed. A failing require costs
-- ~80 us per list row, so the failure is cached too.
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
