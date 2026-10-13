-- One physical monitor shared between nodes: finds it among the attached screens and switches its input.
--   Display.new(id, spec, me, {screens, backend, backendOptions, runner, timer, log = optional})
local Display = {}
Display.__index = Display

local DDC_TIMEOUT = 5
local RETRY_DELAY = 1

local function isUuid(s)
  return s:match("^%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil
end

function Display.new(id, spec, me, deps)
  return setmetatable({
    id = id,
    pull = spec.pull,
    home = spec.home,
    _inputs = spec.inputs,
    _match = spec.match,
    _me = me,
    _deps = deps,
  }, Display)
end

function Display:inputFor(node)
  return self._inputs[node]
end

function Display:_matchFor()
  if type(self._match) == "table" then return self._match[self._me] end
  return self._match
end

function Display:target()
  local pattern = self:_matchFor()
  if pattern == nil then return nil end
  local byUuid = isUuid(pattern)
  local wanted = byUuid and pattern:lower() or nil
  for _, screen in ipairs(self._deps.screens()) do
    if byUuid then
      if screen.uuid ~= nil and screen.uuid:lower() == wanted then return screen end
    elseif screen.name ~= nil and screen.name:find(pattern, 1, true) then
      return screen
    end
  end
  return nil
end

function Display:visible()
  return self:target() ~= nil
end

-- Returns a function(done) that performs one switch attempt, or nil, reason when it cannot start.
function Display:_attempt(node)
  local target = self:target()
  if target == nil then return nil, "not-visible" end
  local input = self:inputFor(node)
  if input == nil then return nil, "unknown-node" end

  local backend = self._deps.backend
  if type(backend) == "function" then
    return function(done)
      backend({ id = self.id, uuid = target.uuid, name = target.name }, input, done)
    end
  end

  local opts = self._deps.backendOptions or {}
  local path = opts.path or backend.defaultPath
  local args = backend.args(target, input, opts)
  return function(done, runner, sync, timeoutSec)
    if sync then return runner:runSync(path, args, timeoutSec) end
    return runner:run(path, args, DDC_TIMEOUT, done)
  end
end

function Display:switchTo(node, done)
  local attempt, reason = self:_attempt(node)
  if attempt == nil then
    done(false, reason)
    return
  end

  local deps = self._deps
  local function try(retriesLeft)
    local settled = false
    attempt(function(ok)
      if settled then return end
      settled = true
      if ok then
        done(true)
      elseif retriesLeft > 0 then
        deps.timer.doAfter(RETRY_DELAY, function() try(retriesLeft - 1) end)
      else
        done(false, "backend-error")
      end
    end, deps.runner, false)
  end
  try(1)
end

function Display:switchToSync(node, timeoutSec)
  local attempt, reason = self:_attempt(node)
  if attempt == nil then return false, reason end

  if type(self._deps.backend) == "function" then
    local result
    attempt(function(ok)
      if result == nil then result = ok == true end
    end)
    if result == nil and not self._warnedSync and self._deps.log then
      self._warnedSync = true
      self._deps.log.w("backend function returned without calling done; the sleep and request paths need " ..
        "synchronous completion, so this switch is treated as failed (see the README's backend section)")
    end
    if result then return true end
    return false, "backend-error"
  end

  if attempt(nil, self._deps.runner, true, timeoutSec) then return true end
  return false, "backend-error"
end

return Display
