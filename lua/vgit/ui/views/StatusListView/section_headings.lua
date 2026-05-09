--[[
  Section heading detection for StatusListView-based J/K navigation.

  Given a StatusListView fold tree, returns a set of folder nodes that
  should be jump targets. Used by ProjectDiffScreen and the by-file
  variant of the project review screen. The rule:

  - Top-level folds (e.g. "Staged Changes", "Changes", "Seen", "Unseen")
    are section wrappers, never headings themselves.
  - For each non-empty folder directly under a top-level fold, walk down
    through single-folder chains (one folder child, no file children).
  - At the first folder that branches (or has any file child), mark each
    of its non-empty folder children as a heading.
  - If the chain bottoms out at a folder with only files, mark the original
    topmost folder.
  - Files at any level are never headings (and orphan files with no
    wrapping folder produce no heading).

  See section_headings_spec.lua for the exact behavior on representative
  trees.
]]

-- A folder is "non-empty" if its subtree contains at least one file.
local function has_files(node)
  if not node.items then return false end
  for _, c in ipairs(node.items) do
    if c.node_type == 'file' then return true end
    if c.node_type == 'folder' and has_files(c) then return true end
  end
  return false
end

-- Returns (non_empty_folder_children, has_any_file_child) for a folder.
local function classify_children(folder)
  local folders, has_file = {}, false
  for _, c in ipairs(folder.items or {}) do
    if c.node_type == 'file' then
      has_file = true
    elseif c.node_type == 'folder' and has_files(c) then
      folders[#folders + 1] = c
    end
  end
  return folders, has_file
end

-- Collect headings for one top-level folder subtree by walking the
-- single-folder chain, then marking branch-point children (or the entry
-- folder if the chain bottoms out at a leaf folder).
local function collect_for(entry_folder, headings)
  local cur = entry_folder
  while true do
    local children, has_file = classify_children(cur)
    -- Single-folder chain: descend.
    if #children == 1 and not has_file then
      cur = children[1]
    -- Branches into multiple folders: each is a heading.
    elseif #children > 0 then
      for _, c in ipairs(children) do headings[c] = true end
      return
    -- Leaf folder (only files): the topmost wrapper is the heading.
    else
      headings[entry_folder] = true
      return
    end
  end
end

return function(folds)
  local headings = {}
  for _, top in ipairs(folds or {}) do
    local children = classify_children(top)
    for _, c in ipairs(children) do
      collect_for(c, headings)
    end
  end
  return headings
end
