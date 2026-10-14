-- Laptop lid sensor. `parse` is pure; the constructor receives the Hammerspoon modules
-- (`screenWatcher` = hs.screen.watcher, `task` = hs.task, `timer` = hs.timer) as parameters.

local LidSensor = {}
LidSensor.__index = LidSensor

-- true = closed, false = open, nil = no AppleClamshellState key (machine without a lid).
function LidSensor.parse(ioregOutput)
  local value = ioregOutput:match('"AppleClamshellState"%s*=%s*(%a+)')
  if value == "Yes" then return true end
  if value == "No" then return false end
  return nil
end

-- opts: screenWatcher, task, timer, debounce (default 1.5 s), ioreg (default /usr/sbin/ioreg).
function LidSensor.new(opts)
  local self = setmetatable({}, LidSensor)
  self._screenWatcher = opts.screenWatcher
  self._task = opts.task
  self._timer = opts.timer
  self._debounce = opts.debounce or 1.5
  self._ioreg = opts.ioreg or "/usr/sbin/ioreg"
  self._closed = nil
  self._generation = 0
  return self
end

function LidSensor:closed()
  return self._closed
end

-- Runs ioreg asynchronously; done(closed|nil) is skipped if the sensor was stopped meanwhile.
function LidSensor:_read(done)
  local generation = self._generation
  local args = { "-r", "-k", "AppleClamshellState", "-d", "1" }
  self._reading = self._task.new(self._ioreg, function(code, stdout)
    if generation ~= self._generation then return end
    self._reading = nil
    local closed
    if code == 0 and type(stdout) == "string" then closed = LidSensor.parse(stdout) end
    done(closed)
  end, args)
  if self._reading == nil then
    done(nil)
    return
  end
  self._reading:start()
end

function LidSensor:_refresh(onChange)
  if self._reading then
    self._again = true
    return
  end
  self:_read(function(closed)
    if closed ~= nil and closed ~= self._closed then
      self._closed = closed
      onChange(closed)
    end
    if self._again then
      self._again = false
      self:_refresh(onChange)
    end
  end)
end

-- onChange(closed: boolean) fires only when the lid state changes after the initial read.
-- onReady(closed: boolean|nil), optional, fires once when the initial read has completed (nil: no lid
-- or ioreg failed); it is not called if the sensor is stopped first.
-- Without a lid (no key, or ioreg failure) the sensor stays inactive and registers no watcher.
function LidSensor:start(onChange, onReady)
  self:stop()
  local generation = self._generation
  self:_read(function(closed)
    self._closed = closed
    if closed ~= nil then
      self._watcher = self._screenWatcher.new(function()
        if self._pending then self._pending:stop() end
        self._pending = self._timer.doAfter(self._debounce, function()
          self._pending = nil
          if generation ~= self._generation then return end
          self:_refresh(onChange)
        end)
      end)
      self._watcher:start()
    end
    if onReady then onReady(closed) end
  end)
end

function LidSensor:stop()
  self._generation = self._generation + 1
  if self._pending then
    self._pending:stop()
    self._pending = nil
  end
  if self._watcher then
    self._watcher:stop()
    self._watcher = nil
  end
  if self._reading then
    if self._reading.isRunning and self._reading:isRunning() then self._reading:terminate() end
    self._reading = nil
  end
  self._again = false
  self._closed = nil
end

return LidSensor
