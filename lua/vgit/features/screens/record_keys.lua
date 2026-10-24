local utils = require('vgit.core.utils')

local record_keys = {}

--[[
  By-commit records are stored under `<subject key>:<filepath>` keys, where
  the subject key hashes the commit's subject: subjects survive rebases,
  commit hashes don't. This module owns that format.

  Rewording a commit's subject orphans its records. jj change ids survive
  rewording, but jj re-derives them for commits it imports from git, so only
  subjects survive git-side rebases. Thus a record is looked up by subject
  key first, and failing that by the change id recorded with it, after which
  it moves to its new subject key.

  Stacked branches share commits, so a (commit, file) with no state in this
  review also adopts the record another branch's review holds for the same
  change id. ReviewState applies the results of these lookups to
  its storage.
]]

-- The subject key of a commit subject. Every stored key depends on
-- utils.str.fnv1a, so it must never change.
function record_keys.subject_key(subject)
  return utils.str.fnv1a(vim.trim(subject))
end

-- The subject keys of a stack's subjects, in stack order. The n-th repeat
-- (n >= 2) of a subject mixes n in, so commits sharing a subject ("wip",
-- "fmt", or none) get records of their own; first occurrences keep the
-- plain key.
function record_keys.subject_keys(subjects)
  local counts, keys = {}, {}
  for i, subject in ipairs(subjects) do
    local trimmed = vim.trim(subject)
    local n = (counts[trimmed] or 0) + 1
    counts[trimmed] = n
    keys[i] = utils.str.fnv1a(n == 1 and trimmed or trimmed .. '\0' .. n)
  end
  return keys
end

function record_keys.join(subject_key, filepath)
  return subject_key .. ':' .. filepath
end

-- A key's subject key and file path. Subject keys are hex, so the path is
-- everything after the first colon.
function record_keys.split(key)
  return key:match('^([^:]*):(.*)$')
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
-- key of `change_ids`, a map of keys holding state to their change ids.
function record_keys.find(items, change_ids)
  local by_identity = {}
  for key, change_id in pairs(change_ids) do
    local _, filepath = record_keys.split(key)
    if filepath then by_identity[change_id .. ':' .. filepath] = key end
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
    if not kept[key] then sources[key] = change_ids[key] end
  end

  local moves, taken = {}, {}
  for _, match in ipairs(record_keys.find(unheld, sources)) do
    if not taken[match.key] then
      taken[match.key] = true
      moves[#moves + 1] = { from = match.key, to = match.item.key }
    end
  end
  return moves
end

return record_keys
