local Config = require('vgit.core.Config')

return Config({
  keymaps = {
    toggle_focus = {
      key = '<Tab>',
      desc = 'Switch focus between file list and diff preview',
    },
    previous = {
      key = 'k',
      desc = 'Previous',
    },
    next = {
      key = 'j',
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
    jump_section_next = {
      key = 'J',
      desc = 'Jump to next section',
    },
    jump_section_prev = {
      key = 'K',
      desc = 'Jump to previous section',
    },
  },
})
