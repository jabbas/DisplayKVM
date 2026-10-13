-- User activity sensor. `classify` and `initialState` are pure (no Hammerspoon access);
-- the constructor receives the Hammerspoon modules (`caffeinate`, `host`) as parameters.

local ActivitySensor = {}
ActivitySensor.__index = ActivitySensor

-- Maps a caffeinate event to "active"/"inactive"/nil and whether the reaction must be synchronous.
function ActivitySensor.classify(eventName, locked, idle, userIdle)
  if eventName == "screensDidUnlock" then
    return "active", false
  elseif eventName == "screensDidWake" or eventName == "systemDidWake" then
    if not locked and idle < userIdle then return "active", false end
    return nil, false
  elseif eventName == "screensDidLock" or eventName == "screensDidSleep" then
    return "inactive", false
  elseif eventName == "systemWillSleep" then
    return "inactive", true
  end
  return nil, false
end

function ActivitySensor.initialState(locked, idle, startIdle)
  return (not locked) and idle < startIdle
end

-- opts: caffeinate (hs.caffeinate), host (hs.host), userIdle (default 5), startIdle (default 30).
function ActivitySensor.new(opts)
  local self = setmetatable({}, ActivitySensor)
  self._caffeinate = opts.caffeinate
  self._host = opts.host
  self._userIdle = opts.userIdle or 5
  self._startIdle = opts.startIdle or 30
  return self
end

function ActivitySensor:isLocked()
  local props = self._caffeinate.sessionProperties()
  return props ~= nil and props.CGSSessionScreenIsLocked == true
end

function ActivitySensor:initial()
  if ActivitySensor.initialState(self:isLocked(), self._host.idleTime(), self._startIdle) then
    return true, "start"
  end
  return false, "start (idle)"
end

local function eventNames(watcher)
  local names = {}
  for key, value in pairs(watcher) do
    if type(value) == "number" then names[value] = key end
  end
  return names
end

-- onChange(active: boolean, reason: string, sync: boolean); reason is the caffeinate event name.
function ActivitySensor:start(onChange)
  self:stop()
  local names = eventNames(self._caffeinate.watcher)
  self._watcher = self._caffeinate.watcher.new(function(event)
    local name = names[event]
    if name == nil then return end
    local state, sync = ActivitySensor.classify(name, self:isLocked(), self._host.idleTime(), self._userIdle)
    if state ~= nil then onChange(state == "active", name, sync) end
  end)
  self._watcher:start()
end

function ActivitySensor:stop()
  if self._watcher then
    self._watcher:stop()
    self._watcher = nil
  end
end

return ActivitySensor
