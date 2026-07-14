local Config = require('vgit.core.Config')

return Config({
  -- Alignment when jumping to a hunk: 'top', 'center', or 'bottom'
  hunk_alignment = 'center',
  -- Width of the file list column in columns
  list_width = 80,
  keymaps = {
    commit = {
      key = 'C',
      desc = 'Commit',
    },
    stage_hunk = {
      key = 's',
      desc = 'Stage hunk (visual: stage selected lines)'
    },
    unstage_hunk = {
      key = 'u',
      desc = 'Unstage hunk (visual: unstage selected lines)'
    },
    reset_hunk = {
      key = 'r',
      desc = 'Reset hunk'
    },
    stage_file = {
      key = 'S',
      desc = 'Stage file'
    },
    unstage_file = {
      key = 'U',
      desc = 'Unstage file'
    },
    reset_file = {
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
