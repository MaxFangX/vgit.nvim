local change_id_rekey = {}

--[[
  Review marks are stored under `<subject hash>:<filepath>` keys, so
  rewording a commit's subject orphans its entries. jj change ids survive
  rewording, but jj re-derives them for commits it imports from git, so only
  subjects survive git-side rebases. Thus an entry is looked up by subject
  key first, and failing that by the change id recorded with it, after which
  it moves to its new subject key.

  Stacked branches share commits, so a (commit, file) with no state in this
  review also adopts the entry another branch's review holds for the same
  change id. ReviewState and IndexedReviewState share these lookups, and
  each applies the results to its own storage.

  Subject hashes are FNV-1a hex, so a key's file path is everything after
  its first colon.
]]

-- The (commit, file) items for the `commits` that have a jj change id, as
-- `{ key, filepath, change_id }` with `key = make_mark_key(subject, filepath)`.
function change_id_rekey.items(commits, commit_files, make_mark_key)
  local items = {}
  for _, commit in ipairs(commits) do
    if commit.change_id then
      for _, file in ipairs(commit_files[commit.hash] or {}) do
        items[#items + 1] = {
          key = make_mark_key(commit.message, file.filepath),
          filepath = file.filepath,
          change_id = commit.change_id,
        }
      end
    end
  end
  return items
end

-- The items with no state under their key in `held_keys` (a set).
function change_id_rekey.unheld(items, held_keys)
  local unheld = {}
  for _, item in ipairs(items) do
    if not held_keys[item.key] then unheld[#unheld + 1] = item end
  end
  return unheld
end

-- Returns `{ item, key }` for each item whose change id and file path match a
-- key in the set `keys`. `change_ids` maps keys to recorded change ids.
function change_id_rekey.find(items, keys, change_ids)
  local by_identity = {}
  for key in pairs(keys) do
    local change_id, filepath = change_ids[key], key:match('^[^:]*:(.*)$')
    if change_id and filepath then by_identity[change_id .. ':' .. filepath] = key end
  end

  local matches = {}
  for _, item in ipairs(items) do
    local key = by_identity[item.change_id .. ':' .. item.filepath]
    if key then matches[#matches + 1] = { item = item, key = key } end
  end
  return matches
end

-- For each item with no state under its key, plans a move from the held key
-- with the same change id and file path. `held_keys` is the set of keys
-- holding state. Returns `{ from, to }` pairs.
function change_id_rekey.plan(items, held_keys, change_ids)
  local moves = {}
  local unheld = change_id_rekey.unheld(items, held_keys)
  for _, match in ipairs(change_id_rekey.find(unheld, held_keys, change_ids)) do
    moves[#moves + 1] = { from = match.key, to = match.item.key }
  end
  return moves
end

return change_id_rekey
