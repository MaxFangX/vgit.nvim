local Config = require('vgit.core.Config')

return Config({
  -- Width of the file list column in columns. The boundary is also
  -- mouse-draggable; a drag updates this value for the rest of the session.
  list_width = 80,
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
      desc = 'Mark hunk seen (visual: mark selected lines)',
    },
    mark_file = {
      key = 'S',
      desc = 'Mark file seen',
    },
    unmark_hunk = {
      key = 'u',
      desc = 'Unmark hunk (visual: unmark selected lines)',
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
