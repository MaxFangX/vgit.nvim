local Config = require('vgit.core.Config')

return Config({
  diff_preference = 'unified',
  -- Wrap the diff's long lines rather than cut them off at the window's edge
  diff_wrap = false,
  keymaps = { quit = '<esc>', toggle_wrap = 'gw' },
})
