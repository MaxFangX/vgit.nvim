local jj = require('vgit.git.jj')
local git_branch = require('vgit.git.git_branch')
local record_keys = require('vgit.features.screens.record_keys')
local ReviewModel = require('vgit.features.screens.ReviewModel')

--[[
  By-commit review model. Each item is a (commit, file) pair diffed against
  the commit's parent, with id `<commit hash>|<path>` and record key
  `<subject key>:<path>`.

  Commit hashes change on rebase but subjects typically survive, so the
  approved snapshot follows the commit across rebases/absorbs — which is the
  whole point: after a fixup is absorbed, diff(approved, new commit content)
  shows only the delta beyond what was already approved. Commits repeating a
  subject key apart by their order (see record_keys.subject_keys).
]]

local Model = ReviewModel:extend()

Model.review_type = 'by_commit'

function Model:fetch_items(target)
  local reponame = self.state.reponame
  local commits, err = git_branch.review_commits(reponame, target.merge_base, target.head_hash)
  if not commits then return nil, err end

  -- In a jj repo, the list shows jj change ids instead of git short hashes
  jj.attach_change_ids(reponame, commits)

  local subject_keys = record_keys.subject_keys(vim.tbl_map(function(commit) return commit.message end, commits))
  local items, rekey_items = {}, {}
  self.state.commits_by_hash = {}
  for i, commit in ipairs(commits) do
    self.state.commits_by_hash[commit.hash] = commit
    for _, file in ipairs(commit.files) do
      local item = ReviewModel.new_item(file, {
        id = commit.hash .. '|' .. file.filepath,
        record_key = record_keys.join(subject_keys[i], file.filepath),
        base_spec = string.format('%s^:%s', commit.hash, file.old_filepath or file.filepath),
        current_spec = string.format('%s:%s', commit.hash, file.filepath),
        commit = commit,
        -- The commit's position from the base, a stable index for the list
        commit_index = i,
      })
      items[#items + 1] = item
      if commit.change_id then
        local rekey_item = { key = item.record_key, filepath = item.filepath, change_id = commit.change_id }
        rekey_items[#rekey_items + 1] = rekey_item
      end
    end
  end

  -- Records stored under a reworded subject, or made while reviewing another
  -- branch, are found by jj change id (see record_keys)
  if #rekey_items > 0 then self.review_state:reconcile_change_ids(rekey_items) end
  return items
end

-- Entries come in item order, so each commit's are consecutive
function Model:group_entries(entries)
  local commits = {}
  for _, entry in ipairs(entries) do
    local group = commits[#commits]
    if not group or group.commit ~= entry.commit then
      group = { commit = entry.commit, files = {}, index = self:item_of(entry).commit_index }
      commits[#commits + 1] = group
    end
    group.files[#group.files + 1] = entry
  end
  return { commits = commits }
end

return Model
