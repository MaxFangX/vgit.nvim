local git_branch = require('vgit.git.git_branch')
local ReviewModel = require('vgit.features.screens.ReviewModel')

--[[
  By-file review model. Each item is a file diffed cumulatively from the
  merge-base to the review head; its id and record key are its path.
]]

local Model = ReviewModel:extend()

Model.review_type = 'by_file'

function Model:fetch_items(target)
  local files, err = git_branch.changed_files(self.state.reponame, target.merge_base, target.head_hash)
  if not files then return nil, err end

  return vim.tbl_map(function(file)
    return ReviewModel.new_item(file, {
      id = file.filepath,
      record_key = file.filepath,
      base_spec = string.format('%s:%s', target.merge_base, file.old_filepath or file.filepath),
      current_spec = string.format('%s:%s', target.head_hash, file.filepath),
    })
  end, files)
end

function Model:group_entries(entries)
  return { entries = entries }
end

return Model
