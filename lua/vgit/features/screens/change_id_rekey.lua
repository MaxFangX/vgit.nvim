local change_id_rekey = {}

--[[
  Review marks are stored under `<subject hash>:<filepath>` keys, so rewording
  a commit's subject orphans its entries. jj change ids survive rewording,
  while subjects survive git-side rebases (jj re-derives change ids for
  commits it imports from git), so an entry is found by either identity:
  looked up by subject key first, and failing that by the change id recorded
  with it, after which it moves to its new subject key. Both review state
  classes share this planning step and apply the moves to their own storage.
]]

-- Plan the moves for the current (commit, file) `items`, each
-- `{ key, filepath, change_id }`: for every item with no state under its
-- key, the held key carrying the same change id and file path under an old
-- subject. `held_keys` is the set of keys currently holding state and
-- `change_ids` maps keys to recorded change ids. Returns `{ from, to }` pairs.
function change_id_rekey.plan(items, held_keys, change_ids)
  local keys_by_change_id = {}
  for key in pairs(held_keys) do
    local change_id = change_ids[key]
    if change_id then
      local keys = keys_by_change_id[change_id] or {}
      keys[#keys + 1] = key
      keys_by_change_id[change_id] = keys
    end
  end

  local moves = {}
  for _, item in ipairs(items) do
    if not held_keys[item.key] then
      local suffix = ':' .. item.filepath
      for _, key in ipairs(keys_by_change_id[item.change_id] or {}) do
        if key:sub(-#suffix) == suffix then
          moves[#moves + 1] = { from = key, to = item.key }
          break
        end
      end
    end
  end
  return moves
end

return change_id_rekey
