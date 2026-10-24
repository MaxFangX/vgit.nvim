--[[
  Walks over FoldableListComponent fold trees. A node with `items` is a fold
  (a section, commit or folder row); a file node carries its entry's `id`.
  Collapsed folds are walked too, so these follow display order whatever is
  open.
]]

local fold_tree = {}

-- File nodes in display order
function fold_tree.file_nodes(folds)
  local files = {}
  local function walk(items)
    for _, node in ipairs(items) do
      if node.items then
        walk(node.items)
      elseif node.id then
        files[#files + 1] = node
      end
    end
  end
  walk(folds or {})
  return files
end

-- The first file node at or under `node`, or nil
function fold_tree.first_file(node)
  if not node.items then return node.id and node or nil end
  for _, child in ipairs(node.items) do
    local file = fold_tree.first_file(child)
    if file then return file end
  end
  return nil
end

-- Nodes from a root of `folds` down to the file node `id`, or nil
function fold_tree.path_to(folds, id)
  local path = {}
  local function walk(items)
    for _, node in ipairs(items) do
      path[#path + 1] = node
      if node.items then
        if walk(node.items) then return true end
      elseif node.id == id then
        return true
      end
      path[#path] = nil
    end
    return false
  end
  return walk(folds or {}) and path or nil
end

return fold_tree
