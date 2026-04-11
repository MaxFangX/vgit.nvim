local Object = require('vgit.core.Object')

local GitPatch = Object:extend()

function GitPatch:constructor(filepath, hunk)
  local header = hunk.header

  if hunk.type == 'add' then
    local previous, _ = hunk:parse_header(header)
    header = string.format('@@ -%s,%s +%s,%s @@', previous[1], previous[2], previous[1] + 1, #hunk.diff)
  end

  local patch = {
    string.format('diff --git a/%s b/%s', filepath, filepath),
    'index 000000..000000',
    string.format('--- a/%s', filepath),
    string.format('+++ a/%s', filepath),
    header,
  }

  for i = 1, #hunk.diff do
    patch[#patch + 1] = hunk.diff[i]
  end

  return patch
end

return GitPatch
