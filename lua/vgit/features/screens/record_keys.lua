local record_keys = {}

--[[
  By-commit records are stored under `<subject hash>:<filepath>` keys, so
  rewording a commit's subject orphans them. jj change ids survive
  rewording, but jj re-derives them for commits it imports from git, so only
  subjects survive git-side rebases. Thus a record is looked up by subject
  key first, and failing that by the change id recorded with it, after which
  it moves to its new subject key.

  Stacked branches share commits, so a (commit, file) with no state in this
  review also adopts the record another branch's review holds for the same
  change id. ReviewState applies the results of these lookups to
  its storage.

  Subject hashes are FNV-1a hex, so a key's file path is everything after
  its first colon.
]]

-- The (commit, file) items for the `commits` that have a jj change id, as
-- `{ key, filepath, change_id }` with `key = make_record_key(subject, filepath)`.
function record_keys.items(commits, commit_files, make_record_key)
  local items = {}
  for _, commit in ipairs(commits) do
    if commit.change_id then
      for _, file in ipairs(commit_files[commit.hash] or {}) do
        items[#items + 1] = {
          key = make_record_key(commit.message, file.filepath),
          filepath = file.filepath,
          change_id = commit.change_id,
        }
      end
    end
  end
  return items
end

-- The items with no state under their key in `held_keys` (a set).
function record_keys.unheld(items, held_keys)
  local unheld = {}
  for _, item in ipairs(items) do
    if not held_keys[item.key] then unheld[#unheld + 1] = item end
  end
  return unheld
end

-- Returns `{ item, key }` for each item whose change id and file path match a
-- key in the set `keys`. `change_ids` maps keys to recorded change ids.
function record_keys.find(items, keys, change_ids)
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
-- holding state. A held key whose recorded change id is another current
-- item's (subjects shifted or swapped) is that item's to move, not this
-- one's to keep. Returns `{ from, to }` pairs, each `from` used once; apply
-- them together, reading every `from` before writing any `to`.
function record_keys.plan(items, held_keys, change_ids)
  local current = {}
  for _, item in ipairs(items) do
    current[item.change_id .. ':' .. item.filepath] = true
  end

  local kept, unheld = {}, {}
  for _, item in ipairs(items) do
    local recorded = change_ids[item.key]
    local claimed = recorded and recorded ~= item.change_id and current[recorded .. ':' .. item.filepath]
    if held_keys[item.key] and not claimed then
      kept[item.key] = true
    else
      unheld[#unheld + 1] = item
    end
  end

  local sources = {}
  for key in pairs(held_keys) do
    if not kept[key] then sources[key] = true end
  end

  local moves, taken = {}, {}
  for _, match in ipairs(record_keys.find(unheld, sources, change_ids)) do
    if not taken[match.key] then
      taken[match.key] = true
      moves[#moves + 1] = { from = match.key, to = match.item.key }
    end
  end
  return moves
end

return record_keys
