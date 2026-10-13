--- === DisplayKVM ===
---
--- Shares one or more monitors between several Macs without a hardware KVM switch.
---
--- Each Mac runs this Spoon. When the user becomes active on a Mac (unlock, wake, start), it
--- switches the shared monitors to its own input over DDC/CI; when the user goes away (lock, sleep,
--- lid closed) it hands the monitors to another active Mac. Nodes find each other with Bonjour (or a
--- static peer list) and exchange HMAC-signed messages over HTTP; no server or cloud is involved.
---
--- Basic usage:
--- ```lua
--- hs.loadSpoon("DisplayKVM")
--- spoon.DisplayKVM:configure({
---   secret = "<64 hex characters from DisplayKVM.generateSecret()>",
---   node = "desk-mini",
---   displays = {
---     main = {
---       match = "DELL U2720Q",
---       inputs = { ["desk-mini"] = 15, laptop = 16 },
---     },
---   },
--- }):bindHotkeys({ claim = { { "ctrl", "alt" }, "k" } }):start()
--- ```
---
--- Download: https://github.com/jabbas/DisplayKVM

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "DisplayKVM"
obj.version = "0.1.0"
obj.author = "Grzegorz Dzięgielewski <jabbas@jabbas.eu>"
obj.license = "MIT - https://opensource.org/licenses/MIT"
obj.homepage = "https://github.com/jabbas/DisplayKVM"

-- The group secret, keyed by the Spoon object. Private to this file and weak-keyed, so it never
-- appears in a table that hs.inspect(spoon.DisplayKVM) would print.
local secrets = setmetatable({}, { __mode = "k" })

local BACKEND_FILES = { "m1ddc", "ddcctl", "betterdisplay", "lunar" }

-- Loads a file that ships with the Spoon. Only called from methods, never at file load.
local function loadModule(file)
  return dofile(hs.spoons.resourcePath(file))
end

local function toHex(bytes)
  return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- `n` random bytes from the system CSPRNG, hex-encoded (2 * n characters).
local function randomHex(n)
  local f = assert(io.open("/dev/urandom", "rb"))
  local bytes = f:read(n)
  f:close()
  assert(bytes and #bytes == n, "cannot read from /dev/urandom")
  return toHex(bytes)
end

function obj:_logger(level)
  if self._log == nil then self._log = hs.logger.new("DisplayKVM", level or "info") end
  if level ~= nil then self._log.setLogLevel(level) end
  return self._log
end

local function builtinBackends(self)
  if self._builtin == nil then
    local backends = {}
    for _, name in ipairs(BACKEND_FILES) do backends[name] = loadModule("backends/" .. name .. ".lua") end
    self._builtin = backends
  end
  return self._builtin
end

--- DisplayKVM:init()
--- Method
--- Spoon initialiser, called by `hs.loadSpoon`. Has no side effects: nothing is started.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DisplayKVM object
function obj:init()
  return self
end

--- DisplayKVM:configure(config) -> DisplayKVM
--- Method
--- Validates and stores the configuration. On an invalid configuration the error is logged and shown
--- as a notification, and `start()` will do nothing until `configure` succeeds.
---
--- Parameters:
---  * config - A table with these keys:
---    * secret - Required. At least 64 hex characters shared by all nodes (see `DisplayKVM.generateSecret()`)
---    * displays - Required. A table mapping a display id to `{ match = ..., inputs = ..., home = ..., pull = ... }`:
---      * match - Required. A string (screen name substring, or a screen UUID) or a table node name -> string
---      * inputs - Required. A table node name -> DDC input value
---      * home - Optional. The node that gets the display on release. Defaults to the first node by name
---      * pull - Optional. Boolean, default `true`. Whether to pull the display from an active peer on claim
---    * node - Optional. This node's name. Defaults to `hs.host.localizedName()`; must appear in some `inputs`
---    * backend - Optional. `"m1ddc"` (default), `"ddcctl"`, `"betterdisplay"`, `"lunar"` or a
---      `function(display, input, done)` that calls `done(true)` or `done(false)`. A function backend
---      **must call `done` before it returns**: handing a request from a peer and going to sleep switch
---      synchronously, and a `done` that has not been called by then counts as a failure. Only the
---      asynchronous claim path tolerates a later `done`. Do the work synchronously (for example with
---      `hs.execute`) or use a built-in backend
---    * backendOptions - Optional. A table, e.g. `{ path = "/path/to/binary" }`
---    * peers - Optional. A list of static `"host:port"` peers, for networks without Bonjour
---    * port - Optional. TCP port of the HTTP server. Default `8765`
---    * bonjour - Optional. Boolean, default `true`. Publish and browse via Bonjour
---    * interface - Optional. Network interface to bind the HTTP server to
---    * activity - Optional. A table `{ userIdle = 5, startIdle = 30, lid = true }`
---    * heartbeat - Optional. Seconds between state broadcasts. Default `30`
---    * logLevel - Optional. A `hs.logger` level name. Default `"info"`
---
--- Returns:
---  * The DisplayKVM object
function obj:configure(raw)
  local log = self:_logger("info")
  local cfg, err = loadModule("config.lua").validate(raw, {
    hostname = hs.host.localizedName(),
    fileExists = function(path) return hs.fs.attributes(path) ~= nil end,
    builtinBackends = builtinBackends(self),
  })
  if not cfg then
    log.e(err)
    hs.notify.new({ title = "DisplayKVM", informativeText = err }):send()
    self._cfg = nil
    secrets[self] = nil
    return self
  end
  -- The secret is kept out of every inspectable field; it is only handed to the Message at start().
  secrets[self] = cfg.secret
  cfg.secret = nil
  self._cfg = cfg
  self:_logger(cfg.logLevel)
  return self
end

local function screens()
  local out = {}
  for _, s in ipairs(hs.screen.allScreens()) do
    out[#out + 1] = { uuid = s:getUUID(), name = s:name() }
  end
  return out
end

local function now()
  return math.floor(hs.timer.secondsSinceEpoch() * 1000)
end

local function hmac(key, data)
  return hs.hash.new("hmacSHA256", key):append(data):finish():value()
end

local function buildNode(self, cfg)
  local log = self:_logger()
  local State = loadModule("state.lua")
  local Message = loadModule("message.lua")
  local Transport = loadModule("transport.lua")
  local Discovery = loadModule("discovery.lua")
  local Instances = loadModule("instances.lua")
  local Display = loadModule("display.lua")
  local ActivitySensor = loadModule("activity.lua")
  local LidSensor = loadModule("lid.lua")
  local Runner = loadModule("runner.lua")
  local Node = loadModule("node.lua")
  local Policy = loadModule("policy.lua")

  local instance = randomHex(8)
  local secret = secrets[self]
  local groupId = hs.hash.new("SHA256"):append(secret):finish():value():sub(1, 8)

  local message = Message.new({
    secret = secret,
    node = cfg.node,
    instance = instance,
    hmac = hmac,
    now = now,
    random = randomHex,
    codec = { encode = hs.json.encode, decode = hs.json.decode },
    window = 30000,
    nonceTtl = 60000,
  })

  local discovery = Discovery.new({
    bonjour = hs.bonjour,
    node = cfg.node,
    port = cfg.port,
    groupId = groupId,
    staticPeers = cfg.peers,
    enabled = cfg.bonjour,
    log = log,
  })

  local transport = Transport.new({
    httpserver = hs.httpserver,
    http = hs.http,
    timer = hs.timer,
    message = message,
    discovery = discovery,
    port = cfg.port,
    interface = cfg.interface,
    log = log,
    now = now,
  })

  local runner = Runner.new({
    task = hs.task,
    timer = hs.timer,
    usleep = hs.timer.usleep,
    clock = hs.timer.secondsSinceEpoch,
  })

  local backend = cfg.backend
  if type(backend) == "string" then backend = builtinBackends(self)[backend] end
  local displays = {}
  for id, spec in pairs(cfg.displays) do
    displays[id] = Display.new(id, spec, cfg.node, {
      screens = screens,
      backend = backend,
      backendOptions = cfg.backendOptions,
      runner = runner,
      timer = hs.timer,
      log = log,
    })
  end

  local activity = ActivitySensor.new({
    caffeinate = hs.caffeinate,
    host = hs.host,
    userIdle = cfg.activity.userIdle,
    startIdle = cfg.activity.startIdle,
  })

  local lid
  if cfg.activity.lid then
    lid = LidSensor.new({ screenWatcher = hs.screen.watcher, task = hs.task, timer = hs.timer })
  end

  return Node.new(cfg, {
    state = State.new(),
    policy = Policy,
    instances = Instances.new(2 * cfg.heartbeat * 1000),
    instance = instance,
    displays = displays,
    transport = transport,
    discovery = discovery,
    activity = activity,
    lid = lid,
    now = now,
    timer = hs.timer,
    log = log,
    notify = function(_, text)
      hs.notify.new({ title = "DisplayKVM", informativeText = text }):send()
    end,
  })
end

--- DisplayKVM:start() -> DisplayKVM
--- Method
--- Starts the HTTP server, Bonjour publishing and browsing, and the activity and lid sensors.
--- Does nothing (apart from logging) when there is no valid configuration. Calling it again restarts the node.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DisplayKVM object
function obj:start()
  local log = self:_logger()
  if self._cfg == nil then
    log.e("not started: no valid configuration (call configure first)")
    return self
  end
  if self._node ~= nil then self:stop() end
  self._node = buildNode(self, self._cfg)
  self._node:start()
  return self
end

--- DisplayKVM:stop() -> DisplayKVM
--- Method
--- Stops the HTTP server, Bonjour, the sensors and any claim in progress. The monitor is left as it is.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DisplayKVM object
function obj:stop()
  if self._node ~= nil then
    self._node:stop()
    self._node = nil
  end
  return self
end

--- DisplayKVM:claim([displayId]) -> DisplayKVM
--- Method
--- Switches a display (or, without an argument, every display this node has an input for) to this node,
--- and marks this node as active. Always switches, even when this node is recorded as the owner.
---
--- Parameters:
---  * displayId - Optional. The id of a display from the configuration
---
--- Returns:
---  * The DisplayKVM object
function obj:claim(displayId)
  if self._node == nil then
    self:_logger().w("claim ignored: DisplayKVM is not running")
    return self
  end
  self._node:claim(displayId)
  return self
end

--- DisplayKVM:release() -> DisplayKVM
--- Method
--- Marks this node as inactive and hands its displays to another active node (or to the display's `home`).
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DisplayKVM object
function obj:release()
  if self._node == nil then
    self:_logger().w("release ignored: DisplayKVM is not running")
    return self
  end
  self._node:release()
  return self
end

--- DisplayKVM:status() -> table|nil
--- Method
--- Returns a snapshot of the node for debugging.
---
--- Parameters:
---  * None
---
--- Returns:
---  * `nil` when not running, otherwise a table `{ node = ..., instance = ..., peers = ..., displays = ... }`
---    where `peers[name]` is `{ lastSeen = ms|nil, active = boolean|nil, alive = boolean }` and
---    `displays[id]` is `{ owner = node|nil, visible = boolean, input = number|nil }`
function obj:status()
  if self._node == nil then return nil end
  return self._node:status()
end

--- DisplayKVM:bindHotkeys(mapping) -> DisplayKVM
--- Method
--- Binds hotkeys for DisplayKVM.
---
--- Parameters:
---  * mapping - A table with these keys, each a hotkey spec as accepted by `hs.spoons.bindHotkeysToSpec`:
---    * claim - Switch every display to this Mac
---    * release - Hand the displays over to another Mac
---
--- Returns:
---  * The DisplayKVM object
function obj:bindHotkeys(mapping)
  hs.spoons.bindHotkeysToSpec({
    claim = function() self:claim() end,
    release = function() self:release() end,
  }, mapping)
  return self
end

--- DisplayKVM.generateSecret() -> string
--- Function
--- Generates a random shared secret: 32 bytes from `/dev/urandom` as 64 hex characters.
--- Run it once and put the same value into the configuration of every Mac.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A 64-character hex string
function obj.generateSecret()
  return randomHex(32)
end

return obj
