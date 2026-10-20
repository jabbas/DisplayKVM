-- Away: hides a display from this node by mirroring it onto another screen (design R2, fact F8).
-- Measured on real hardware: `screen:mirrorOf(other)` makes the mirrored screen vanish from
-- hs.screen.allScreens(), the cursor is clamped and the windows move to the target keeping their offset
-- (partly off the edge); `target:mirrorStop()` called on the TARGET restores the layout and the windows
-- return by themselves.
--
--   Away.new(deps)
--
-- deps (the module never touches `hs`; the Spoon passes the hs.* pieces in):
--   find      function(uuid) -> screen|nil
--   primary   function() -> screen
--   all       function() -> {screen}
--   windows   function() -> {window}
--   timer     hs.timer-like: doAfter(sec, fn) -> object with :stop()
--   log       optional {d, i, w, e}
--   settle    seconds to wait after a mirror before pulling the windows back into bounds (default 2)
-- A `screen` has :getUUID() :mirrorOf(other) -> bool :mirrorStop() -> bool; a `window` :ensureIsInScreenBounds().

local Away = {}
Away.__index = Away

local DEFAULT_SETTLE = 2

local noop = function() end

function Away.new(deps)
  return setmetatable({
    _find = deps.find,
    _primary = deps.primary,
    _all = deps.all,
    _windows = deps.windows,
    _timer = deps.timer,
    _log = deps.log or { d = noop, i = noop, w = noop, e = noop },
    _settle = deps.settle or DEFAULT_SETTLE,
  }, Away)
end

-- Explicit target uuid, else the primary screen when it is not the source, else the first other screen.
function Away:_pickTarget(sourceUuid, targetUuid)
  if targetUuid ~= nil then return self._find(targetUuid) end
  local ok, primary = pcall(self._primary)
  if ok and primary ~= nil and primary:getUUID() ~= sourceUuid then return primary end
  for _, screen in ipairs(self._all()) do
    if screen:getUUID() ~= sourceUuid then return screen end
  end
  return nil
end

function Away:_cancelSettle()
  if self._settleTimer then
    self._settleTimer:stop()
    self._settleTimer = nil
  end
end

-- Windows that stayed half off the edge after the mirror are pulled back in.
function Away:_pullWindowsBack()
  self._settleTimer = nil
  for _, window in ipairs(self._windows()) do
    local ok, err = pcall(window.ensureIsInScreenBounds, window)
    if not ok then self._log.d("could not move a window back into bounds: " .. tostring(err)) end
  end
end

-- Mirrors the screen `sourceUuid` onto `targetUuid` (nil: pick one). Returns ok, usedTargetUuid.
function Away:mirror(sourceUuid, targetUuid)
  local source = self._find(sourceUuid)
  if source == nil then
    self._log.d("cannot mirror: screen " .. tostring(sourceUuid) .. " not found")
    return false
  end
  local target = self:_pickTarget(sourceUuid, targetUuid)
  if target == nil then
    self._log.d("cannot mirror: no screen to mirror " .. tostring(sourceUuid) .. " onto")
    return false
  end
  local ok, result = pcall(source.mirrorOf, source, target)
  if not ok or not result then
    self._log.d("mirrorOf failed: " .. tostring(result))
    return false
  end
  self:_cancelSettle()
  self._settleTimer = self._timer.doAfter(self._settle, function() self:_pullWindowsBack() end)
  return true, target:getUUID()
end

-- Stops the mirror; as measured (F8) mirrorStop is called on the screen that was mirrored onto.
function Away:unmirror(targetUuid)
  local target = self._find(targetUuid)
  if target == nil then
    self._log.d("cannot stop mirroring: screen " .. tostring(targetUuid) .. " not found")
    return false
  end
  self:_cancelSettle()
  local ok, result = pcall(target.mirrorStop, target)
  if not ok or not result then
    self._log.d("mirrorStop failed: " .. tostring(result))
    return false
  end
  return true
end

return Away
