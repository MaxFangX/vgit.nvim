local Config = require('vgit.core.Config')

return Config({
  -- Width of the stash list column in columns
  list_width = 80,
  keymaps = {
    add = {
      key = 'A',
      desc = 'Add stash',
    },
    apply = {
      key = 'a',
      desc = 'Apply stash',
    },
    pop = {
      key = 'p',
      desc = 'Pop stash',
    },
    drop = {
      key = 'd',
      desc = 'Drop stash',
    },
    clear = {
      key = 'C',
      desc = 'Clear stash'
    }
  },
})
