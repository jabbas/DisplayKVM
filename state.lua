-- Replicated state: last-writer-wins registers for display owners and node presence.
-- Pure module: no dependency on Hammerspoon.

local State = {}
State.__index = State

function State.new()
  return setmetatable({ _owner = {}, _presence = {} }, State)
end

-- True when owner record `a` beats record `b`: higher ts wins, equal ts -> greater node name.
function State.ownerWins(a, b)
  if a.ts ~= b.ts then return a.ts > b.ts end
  return a.node > b.node
end

local function validOwner(r)
  return type(r) == "table" and type(r.node) == "string" and type(r.ts) == "number"
end

local function validPresence(r)
  return type(r) == "table" and type(r.active) == "boolean"
    and type(r.since) == "number" and type(r.ts) == "number"
end

-- Returns a map-like table or an empty one (JSON codecs may turn {} into []).
local function asMap(t)
  if type(t) ~= "table" then return {} end
  return t
end

function State:setOwner(display, node, ts)
  local cur = self._owner[display]
  local new = { node = node, ts = ts }
  if cur and not State.ownerWins(new, cur) then return false end
  self._owner[display] = new
  return true
end

function State:setPresence(node, active, since, ts)
  local cur = self._presence[node]
  if cur and ts <= cur.ts then return false end
  self._presence[node] = { active = active, since = since, ts = ts }
  return true
end

function State:owner(display)
  local r = self._owner[display]
  if not r then return nil end
  return r.node, r.ts
end

function State:presence(node)
  local r = self._presence[node]
  if not r then return nil end
  return { active = r.active, since = r.since, ts = r.ts }
end

function State:merge(snapshot)
  local changes = {}
  snapshot = asMap(snapshot)
  for display, r in pairs(asMap(snapshot.owner)) do
    if type(display) == "string" and validOwner(r) and self:setOwner(display, r.node, r.ts) then
      changes[#changes + 1] = { kind = "owner", key = display }
    end
  end
  for node, r in pairs(asMap(snapshot.presence)) do
    if type(node) == "string" and validPresence(r) and self:setPresence(node, r.active, r.since, r.ts) then
      changes[#changes + 1] = { kind = "presence", key = node }
    end
  end
  return changes
end

function State:snapshot()
  local snap = { owner = {}, presence = {} }
  for display, r in pairs(self._owner) do
    snap.owner[display] = { node = r.node, ts = r.ts }
  end
  for node, r in pairs(self._presence) do
    snap.presence[node] = { active = r.active, since = r.since, ts = r.ts }
  end
  return snap
end

function State.fromSnapshot(t)
  local s = State.new()
  s:merge(t)
  return s
end

return State
