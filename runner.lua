-- Runs external commands through hs.task with a hard timeout. Dependencies are injected:
--   Runner.new({task = hs.task, timer = hs.timer, usleep = hs.timer.usleep, clock = os.clock-like seconds})
local Runner = {}
Runner.__index = Runner

function Runner.new(deps)
  return setmetatable({
    task = deps.task,
    timer = deps.timer,
    usleep = deps.usleep,
    clock = deps.clock,
  }, Runner)
end

local function failureOutput(stdout, stderr)
  if stderr ~= nil and stderr ~= "" then return stderr end
  return stdout or ""
end

-- Async: done(ok, output) is called exactly once, with (false, "timeout") when the limit is hit.
function Runner:run(path, args, timeoutSec, done)
  local finished = false
  local timeout

  local function finish(ok, output)
    if finished then return end
    finished = true
    if timeout then timeout:stop() end
    done(ok, output)
  end

  local created, instance = pcall(self.task.new, path, function(code, stdout, stderr)
    if code == 0 then
      finish(true, stdout or "")
    else
      finish(false, failureOutput(stdout, stderr))
    end
  end, args)
  if not created or instance == nil then
    finish(false, "start-failed")
    return
  end

  local started = pcall(function() instance:start() end)
  if not started then
    finish(false, "start-failed")
    return
  end

  if finished then return end
  timeout = self.timer.doAfter(timeoutSec, function()
    if finished then return end
    finish(false, "timeout")
    instance:terminate()
  end)
end

-- Blocking variant for the sleep path: polls until the task ends or the limit expires.
function Runner:runSync(path, args, timeoutSec)
  local captured
  local created, instance = pcall(self.task.new, path, function(_, stdout, stderr)
    captured = failureOutput(stdout, stderr)
  end, args)
  if not created or instance == nil then return false, "start-failed" end
  if not pcall(function() instance:start() end) then return false, "start-failed" end

  local deadline = self.clock() + timeoutSec
  while instance:isRunning() and self.clock() < deadline do
    self.usleep(20000)
  end

  if instance:isRunning() then
    instance:terminate()
    return false, "timeout"
  end
  if instance:terminationStatus() == 0 then return true, "" end
  return false, captured or ""
end

return Runner
