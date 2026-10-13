-- Shared test doubles that mirror the Hammerspoon APIs used by the Spoon, so production
-- code receives them exactly like the real `hs.*` modules. Usage in a spec:
--   local fakes = dofile("spec/support/fakes.lua")
--
-- fakes.timer()                       -- controllable clock + scheduler (mirrors hs.timer)
--   timer.now()                       -- current fake time in seconds (starts at 0)
--   timer.doAfter(sec, fn) -> {stop(), running()}
--   timer.doEvery(sec, fn) -> {stop(), running()}
--   timer.advance(sec)                -- moves the clock, firing due timers in order
--   timer.pending() -> number         -- count of live (not stopped, not fired) timers
--
-- fakes.task(script, opts)            -- mirrors the hs.task module
--   script: list of results {code, stdout, stderr}; instance N gets script[N] (default {0, "", ""}).
--           An entry may also be a function(path, args) returning such a table.
--   opts.timer, opts.latency: if given, an instance completes `latency` (default 0) seconds after
--           :start() when the timer is advanced; otherwise the test completes it manually.
--   task.new(path, callback, args) -> {start(), isRunning(), terminate(), terminationStatus()}
--           (task(...) is an alias); terminationStatus() is the exit code once finished (15 if
--           terminated), nil before that
--           terminate() on a running instance marks it terminated and invokes callback(15, "", "")
--           synchronously, like the real hs.task; on a finished/unstarted instance it is a no-op.
--   task.created                      -- every instance: {path, args, started, terminated, done}
--   task.finish([n])                  -- completes instance n (default: oldest started, running one);
--                                        returns the instance
--
-- fakes.host(idle)                    -- mirrors hs.host: host.idleTime() returns host.idle (seconds)
--
-- fakes.caffeinate()                  -- mirrors hs.caffeinate
--   caffeinate.watcher.<name> = number constants, caffeinate.watcher.new(fn) -> {start, stop}
--   caffeinate.sessionProperties()    -- returns {CGSSessionScreenIsLocked = caffeinate.locked},
--                                        or nil when caffeinate.noProps is true
--   caffeinate.emit(name)             -- delivers the named event to the started watcher
--   caffeinate.watchers               -- all created watchers: {started, stopped}
--
-- fakes.screenWatcher()               -- mirrors hs.screen.watcher
--   screenWatcher.new(fn) -> {start, stop}
--   screenWatcher.fire()              -- calls the callback of every started watcher
--   screenWatcher.watchers            -- all created watchers: {started, stopped}
--
-- fakes.httpserver()                  -- mirrors hs.httpserver
--   httpserver.new(ssl, bonjour) -> {setPort(n), setInterface(s), setCallback(fn), start(), stop()}
--           (colon methods, like the real object)
--           (setters return the server); fields: ssl, bonjour, port, interface, callback, started, stopped
--   server:maxBodySize([n]), server:getPort() (0 unless listening); like Hammerspoon, start() never raises:
--           set httpserver.failStart = true to make servers fail to listen
--   server.request(method, path, headers, body) -> body, status, headers
--           calls the callback like the real server does; errors if no callback is set
--   httpserver.created                -- every server created
--
-- fakes.http()                        -- mirrors hs.http
--   http.asyncPost(url, data, headers, cb) -- records {url, data, headers, cb, delivered}; never
--           answers on its own, the test delivers explicitly
--   http.deliver(status, body, headers) -- calls the callback of the latest post; http.deliverTo(n, ...)
--           does the same for post n. Either may be called repeatedly to simulate a late or
--           duplicate callback
--   http.posts                        -- every asyncPost call
--   http.doRequest(url, method, data, headers) -> status, body, headers
--           records {url, method, data, headers} in http.requests and delegates to http.sync(call)
--           (default returns 204, "", {}); a test overrides http.sync, e.g. to raise an error
--   http.requests                     -- every doRequest call
--
-- fakes.bonjour()                     -- mirrors hs.bonjour
--   bonjour.new() -> browser {findServices(type, domain, cb), stop()}; the callback receives
--           (browser, "local.", isAdded, service, moreComing); fields: serviceType, domain, stopped
--   browser.add(svc) / browser.remove(svc) -- fire the callback with isAdded true / false
--   bonjour.browsers                  -- every browser created
--   bonjour.service.new(name, type, port) -> published service {name(), txtRecord(tbl), publish(), stop(),
--           rename(newName), resolve()}; resolve raises like real Hammerspoon ("can't resolve a service
--           created for publishing"); rename simulates a Bonjour collision rename;
--           fields: serviceType, port, txt, published, stopped
--   bonjour.published                 -- every service created through service.new
--   bonjour.remote({name, host, port, txt, result, err}) -> remote service object with
--           :name(), :hostname(), :port(), :txtRecord(), :resolve(timeout, cb)
--           resolve records svc.timeout and svc.resolveCb; if `result` is "resolved", "error" (with
--           `err` as message) or "stop" the callback is invoked at once, otherwise the test calls
--           svc.complete(result, msg) later

local fakes = {}

function fakes.timer()
  local timer = { _now = 0, _seq = 0, _entries = {} }

  function timer.now() return timer._now end

  local function schedule(sec, fn, repeating)
    timer._seq = timer._seq + 1
    local entry = { due = timer._now + sec, seq = timer._seq, fn = fn, interval = repeating and sec or nil }
    entry.live = true
    timer._entries[#timer._entries + 1] = entry
    return {
      stop = function() entry.live = false end,
      running = function() return entry.live end,
    }
  end

  function timer.doAfter(sec, fn) return schedule(sec, fn, false) end
  function timer.doEvery(sec, fn) return schedule(sec, fn, true) end

  function timer.pending()
    local n = 0
    for _, e in ipairs(timer._entries) do
      if e.live then n = n + 1 end
    end
    return n
  end

  local function nextDue(limit)
    local best
    for _, e in ipairs(timer._entries) do
      local earlier = best == nil or e.due < best.due or (e.due == best.due and e.seq < best.seq)
      if e.live and e.due <= limit and earlier then best = e end
    end
    return best
  end

  function timer.advance(sec)
    local limit = timer._now + sec
    while true do
      local e = nextDue(limit)
      if e == nil then break end
      timer._now = e.due
      if e.interval then
        e.due = e.due + e.interval
        timer._seq = timer._seq + 1
        e.seq = timer._seq
      else
        e.live = false
      end
      e.fn()
    end
    timer._now = limit
    local kept = {}
    for _, e in ipairs(timer._entries) do
      if e.live then kept[#kept + 1] = e end
    end
    timer._entries = kept
  end

  return timer
end

function fakes.task(script, opts)
  script = script or {}
  opts = opts or {}
  local task = { created = {} }

  local function complete(inst)
    if inst.done or inst.terminated then return end
    inst.done = true
    inst.running = false
    local r = inst.result
    inst.callback(r[1], r[2], r[3])
  end

  function task.new(path, callback, args)
    local inst = { path = path, args = args, callback = callback, started = false, done = false }
    task.created[#task.created + 1] = inst
    local n = #task.created
    local entry = script[n]
    if type(entry) == "function" then entry = entry(path, args) end
    entry = entry or {}
    inst.result = { entry[1] or 0, entry[2] or "", entry[3] or "" }
    function inst.start()
      inst.started = true
      inst.running = true
      if opts.timer then opts.timer.doAfter(opts.latency or 0, function() complete(inst) end) end
      return inst
    end
    function inst.isRunning() return inst.running == true end
    -- Exit code once the instance has finished (15 after terminate()), nil while it is unfinished.
    function inst.terminationStatus()
      if inst.terminated then return 15 end
      if inst.done then return inst.result[1] end
      return nil
    end
    -- Like the real hs.task, terminating a running task still invokes its callback (SIGTERM -> 15).
    function inst.terminate()
      if not inst.running then return inst end
      inst.terminated = true
      inst.done = true
      inst.running = false
      inst.callback(15, "", "")
      return inst
    end
    return inst
  end

  function task.finish(n)
    local inst = n and task.created[n]
    if n == nil then
      for _, c in ipairs(task.created) do
        if c.started and not c.done and not c.terminated then inst = c break end
      end
    end
    assert(inst, "fakes.task: no running instance to finish")
    complete(inst)
    return inst
  end

  return setmetatable(task, { __call = function(_, ...) return task.new(...) end })
end

function fakes.host(idle)
  local host = { idle = idle or 0 }
  function host.idleTime() return host.idle end
  return host
end

local function watcherFactory(onFire)
  local factory = { watchers = {} }
  function factory.new(fn)
    local w = { started = false, stopped = false, fn = fn }
    function w.start() w.started = true w.stopped = false return w end
    function w.stop() w.started = false w.stopped = true return w end
    factory.watchers[#factory.watchers + 1] = w
    return w
  end
  function factory.each(...)
    for _, w in ipairs(factory.watchers) do
      if w.started then onFire(w, ...) end
    end
  end
  return factory
end

function fakes.caffeinate()
  local factory = watcherFactory(function(w, value) w.fn(value) end)
  local constants = {
    systemDidWake = 0, systemWillSleep = 1, systemWillPowerOff = 3,
    screensDidSleep = 6, screensDidWake = 7, screensDidLock = 10, screensDidUnlock = 11,
  }
  local watcher = { new = factory.new }
  for name, value in pairs(constants) do watcher[name] = value end
  local c = { watcher = watcher, watchers = factory.watchers, locked = false, noProps = false }
  function c.sessionProperties()
    if c.noProps then return nil end
    return { CGSSessionScreenIsLocked = c.locked }
  end
  function c.emit(name)
    assert(constants[name], "unknown caffeinate event " .. tostring(name))
    factory.each(constants[name])
  end
  return c
end

function fakes.screenWatcher()
  local factory = watcherFactory(function(w) w.fn() end)
  return { new = factory.new, watchers = factory.watchers, fire = function() factory.each() end }
end

function fakes.httpserver()
  local httpserver = { created = {} }
  function httpserver.new(ssl, bonjour)
    local server = { ssl = ssl, bonjour = bonjour, started = false, stopped = false }
    function server.setPort(_, n) server.port = n return server end
    function server.setInterface(_, s) server.interface = s return server end
    function server.setCallback(_, fn) server.callback = fn return server end
    -- Like Hammerspoon, start() never raises and always returns the server; a failure to listen
    -- (httpserver.failStart = true) is only visible as getPort() == 0.
    function server.start()
      server.started = not httpserver.failStart
      server.stopped = false
      return server
    end
    function server.getPort() return server.started and server.port or 0 end
    function server.maxBodySize(_, n)
      if n == nil then return server.maxBody or 10485760 end
      server.maxBody = n
      return server
    end
    function server.stop() server.started = false server.stopped = true return server end
    function server.request(method, path, headers, body)
      assert(server.callback, "fakes.httpserver: no callback set")
      return server.callback(method, path, headers or {}, body or "")
    end
    httpserver.created[#httpserver.created + 1] = server
    return server
  end
  return httpserver
end

function fakes.http()
  local http = { posts = {}, requests = {} }
  function http.asyncPost(url, data, headers, cb)
    http.posts[#http.posts + 1] = { url = url, data = data, headers = headers, cb = cb }
  end
  function http.deliverTo(n, status, body, headers)
    local post = assert(http.posts[n], "fakes.http: no such post")
    post.delivered = true
    post.cb(status, body, headers or {})
  end
  function http.deliver(status, body, headers) http.deliverTo(#http.posts, status, body, headers) end
  function http.sync() return 204, "", {} end
  function http.doRequest(url, method, data, headers)
    local call = { url = url, method = method, data = data, headers = headers }
    http.requests[#http.requests + 1] = call
    return http.sync(call)
  end
  return http
end

function fakes.bonjour()
  local bonjour = { browsers = {}, published = {}, service = {} }

  function bonjour.new()
    local browser = { stopped = false }
    function browser.findServices(_, serviceType, domain, cb)
      browser.serviceType, browser.domain, browser.cb = serviceType, domain, cb
      return browser
    end
    function browser.stop() browser.stopped = true return browser end
    function browser.add(svc) browser.cb(browser, "local.", true, svc, false) end
    function browser.remove(svc) browser.cb(browser, "local.", false, svc, false) end
    bonjour.browsers[#bonjour.browsers + 1] = browser
    return browser
  end

  function bonjour.service.new(name, serviceType, port)
    local svc = { serviceType = serviceType, port = port, published = false, stopped = false }
    local current = name
    function svc.name() return current end
    function svc.rename(newName) current = newName end -- Bonjour renames on a name collision
    -- Like real Hammerspoon, a service created for publishing cannot be resolved.
    function svc.resolve() error("can't resolve a service created for publishing", 2) end
    function svc.txtRecord(_, tbl) svc.txt = tbl return svc end
    function svc.publish() svc.published = true return svc end
    function svc.stop() svc.published = false svc.stopped = true return svc end
    bonjour.published[#bonjour.published + 1] = svc
    return svc
  end

  function bonjour.remote(spec)
    local svc = {}
    function svc.name() return spec.name end
    function svc.hostname() return spec.host end
    function svc.port() return spec.port end
    function svc.txtRecord() return spec.txt end
    function svc.complete(result, msg) svc.resolveCb(svc, result, msg) end
    function svc.resolve(_, timeout, cb)
      svc.timeout, svc.resolveCb = timeout, cb
      if spec.result == "error" then cb(svc, "error", spec.err or "timeout")
      elseif spec.result then cb(svc, spec.result) end
      return svc
    end
    return svc
  end

  return bonjour
end

return fakes
