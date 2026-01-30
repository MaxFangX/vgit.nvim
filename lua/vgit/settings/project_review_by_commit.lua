local Config = require('vgit.core.Config')

return Config({
  list_position = 'left',
  hunk_alignment = 'center',
  keymaps = {
    toggle_focus = {
      key = '<Tab>',
      desc = 'Switch focus between file list and diff preview',
    },
    previous = {
      key = 'K',
      desc = 'Previous',
    },
    next = {
      key = 'J',
      desc = 'Next',
    },
    mark_hunk = {
      key = 's',
      desc = 'Mark hunk seen',
    },
    mark_file = {
      key = 'S',
      desc = 'Mark file seen',
    },
    unmark_hunk = {
      key = 'u',
      desc = 'Unmark hunk',
    },
    unmark_file = {
      key = 'U',
      desc = 'Unmark file',
    },
    reset = {
      key = 'R',
      desc = 'Reset all marks',
    },
  },
})
