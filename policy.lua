-- Claim/release decisions. Pure module: no dependency on Hammerspoon or on State's implementation;
-- `state` is passed in and only queried through :owner() and :presence().

local Policy = {}

local function sortedDisplayIds(cfg)
  local ids = {}
  for id in pairs(cfg.displays) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

-- Displays to claim when `me` becomes active: every display that has an input for me.
-- The recorded owner is deliberately ignored (it may be stale; switching is idempotent).
function Policy.onActive(_, cfg, me)
  local result = {}
  for _, id in ipairs(sortedDisplayIds(cfg)) do
    if cfg.displays[id].inputs[me] ~= nil then result[#result + 1] = id end
  end
  return result
end

-- Best peer for a display: alive, active, has an input; latest `since` wins, tie -> greater name.
local function pickPeer(state, display, me, alive)
  local best, bestSince
  for node in pairs(display.inputs) do
    if node ~= me and alive(node) == true then
      local p = state:presence(node)
      if p and p.active == true then
        if best == nil or p.since > bestSince or (p.since == bestSince and node > best) then
          best, bestSince = node, p.since
        end
      end
    end
  end
  return best
end

-- Displays owned by `me` to hand over when `me` goes inactive, with the target node for each.
function Policy.onInactive(state, cfg, me, alive)
  local result = {}
  for _, id in ipairs(sortedDisplayIds(cfg)) do
    local display = cfg.displays[id]
    if state:owner(id) == me then
      local target = pickPeer(state, display, me, alive)
      if target == nil and display.home ~= me then target = display.home end
      if target ~= nil then result[#result + 1] = { display = id, target = target } end
    end
  end
  return result
end

return Policy
