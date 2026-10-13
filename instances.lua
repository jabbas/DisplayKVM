-- Detects two live processes that use the same node name. Pure module: time is passed in.
-- Every start of a node has a fresh random `instance`. A new instance simply replaces the old one
-- (reload or restart). Only an OLDER instance heard again shortly after a newer one appeared
-- means two processes are running at once.

local Instances = {}
Instances.__index = Instances

-- windowMs: how long after a newer instance appeared an older one counts as a duplicate.
function Instances.new(windowMs)
  return setmetatable({ _window = windowMs, _nodes = {} }, Instances)
end

-- Records a message from `name` carrying `instance`. Returns one of:
--   "first"     no instance known for this node yet
--   "same"      the current instance
--   "replaced"  an unknown instance took over from the previous one
--   "duplicate" a retired instance spoke within the window after the current one appeared
--   "stale"     a retired instance spoke after the window (ignored)
function Instances:observe(name, instance, now)
  if type(instance) ~= "string" then return "same" end
  local rec = self._nodes[name]
  if rec == nil then
    self._nodes[name] = { current = instance, seenAt = now, retired = {} }
    return "first"
  end
  if rec.current == instance then return "same" end
  if rec.retired[instance] then
    if now - rec.seenAt <= self._window then return "duplicate" end
    return "stale"
  end
  rec.retired[rec.current] = true
  rec.current = instance
  rec.seenAt = now
  return "replaced"
end

return Instances
