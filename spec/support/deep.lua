-- Test helper: does `value` appear anywhere inside `root`?
-- Walks tables (keys, values and metatables, including __index tables) with a visited set, the way
-- hs.inspect would, and also looks for `value` as a substring of any string. Upvalues are not
-- visible to inspection and are deliberately not followed.

local function deepContains(root, value)
  local visited = {}

  local function matches(x)
    if x == value then return true end
    return type(x) == "string" and type(value) == "string" and x:find(value, 1, true) ~= nil
  end

  local function walk(x)
    if matches(x) then return true end
    if type(x) ~= "table" or visited[x] then return false end
    visited[x] = true
    for k, v in pairs(x) do
      if walk(k) or walk(v) then return true end
    end
    local mt = getmetatable(x)
    if type(mt) == "table" then
      if walk(mt) then return true end
    end
    return false
  end

  return walk(root)
end

return deepContains
