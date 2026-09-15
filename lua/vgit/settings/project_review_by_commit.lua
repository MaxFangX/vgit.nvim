local Config = require('vgit.core.Config')

return Config({
  list_position = 'left',
  -- Width of the file list column (left/right layouts). 0 = auto: size to
  -- the widest commit row, clamped to [72, 45% of the editor]. Set a
  -- positive number for a fixed width instead.
  list_width = 0,
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
      desc = 'Jump to next commit',
    },
    jump_section_prev = {
      key = 'K',
      desc = 'Jump to previous commit',
    },
  },
})
