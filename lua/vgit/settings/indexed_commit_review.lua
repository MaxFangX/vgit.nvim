local Config = require('vgit.core.Config')

return Config({
  list_position = 'left',
  -- Width of the file list column in columns (left/right layouts). 72 fits
  -- convention-wrapped commit message bodies exactly. The boundary is also
  -- mouse-draggable in left layout; a drag updates this value for the rest
  -- of the session.
  list_width = 72,
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
      desc = 'Jump to next commit',
    },
    jump_section_prev = {
      key = 'K',
      desc = 'Jump to previous commit',
    },
  },
})
