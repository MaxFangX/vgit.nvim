local Config = require('vgit.core.Config')

return Config({
  -- Alignment when jumping to a hunk: 'top', 'center', or 'bottom'
  hunk_alignment = 'center',
  keymaps = {
    commit = {
      key = 'C',
      desc = 'Commit',
    },
    buffer_hunk_stage = {
      key = 's',
      desc = 'Stage hunk'
    },
    buffer_hunk_unstage = {
      key = 'u',
      desc = 'Unstage hunk'
    },
    buffer_hunk_reset = {
      key = 'r',
      desc = 'Reset hunk'
    },
    buffer_stage = {
      key = 'S',
      desc = 'Stage file'
    },
    buffer_unstage = {
      key = 'U',
      desc = 'Unstage file'
    },
    buffer_reset = {
      key = 'R',
      desc = 'Reset file'
    },
    toggle_focus = {
      key = '<Tab>',
      desc = 'Switch focus between file list and diff preview'
    },
    next = {
      key = 'j',
      desc = 'Next'
    },
    previous = {
      key = 'k',
      desc = 'Previous'
    },
    jump_section_next = {
      key = 'J',
      desc = 'Next section'
    },
    jump_section_prev = {
      key = 'K',
      desc = 'Previous section'
    },
  },
})
