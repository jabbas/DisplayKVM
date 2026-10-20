-- luacheck: ignore 212/self
-- Scenario simulator: several real Node/State/Policy/Instances objects wired to in-memory fakes.
--   local Sim = dofile("spec/support/sim.lua")
--   local sim = Sim.new({ nodes = {"desk-mini", "laptop"}, home = "desk-mini",
--                         monitor = { inputs = {["desk-mini"] = 15, laptop = 16}, mode = "detaching" } })
--   sim:start(); sim:activate("laptop"); sim:advance(1); assert(sim:input() == 16)
--
-- Options (Sim.new):
--   nodes        list of node names (all are built, none started until sim:start)
--   monitor      {inputs = node -> DDC input, mode = "detaching"|"sticky", acceptsInactive = bool,
--                 input = start input (default: the home node's input),
--                 control = list of nodes allowed to run DDC (default: every node in inputs, sorted),
--                 noDdc = list of nodes whose backend reports success but never changes the monitor
--                 (fact F1: Mac mini HDMI); their backend calls are counted by sim:ddcCalls(name)}
--   home, pull   display settings (pull defaults to true), displayId (default "left")
--   heartbeat    seconds (default 30)         latency  network one-way delay in seconds (default 0.01)
--   partitionMode "unreachable" (default): a send involving a partitioned node fails at once with
--                 status "unreachable"; "timeout": it fails after the 5 s soft timeout with "timeout".
--                 A reply lost to a partition always fails with "timeout" after the soft timeout.
--   mute         {name = true}: that node's Discovery reports no peers, so it never initiates contact
--   static       {node = "host:port"}: every other node reaches that node only by the address (as with
--                 static peers and no mDNS) until a reply teaches the alias, like the real Transport.
--                 Like the real Discovery, a static address is announced (onUp) only when the node
--                 itself starts, never when the peer behind it starts later.
--   lid          true enables the lid sensor in the node config
--   whenAway, mirrorTo   the display options of the same name (node -> "mirror" / screen uuid); every
--                 node gets a fake `away` whose mirror hides the display from that node (fact F8:
--                 the screen leaves allScreens). sim.mirrorFails[name] / sim.unmirrorFails[name] = true
--                 make its mirror() / unmirror() fail; sim.mirroring[name] = true before the node
--                 starts simulates a mirror left over from a crashed or reloaded run (start only
--                 the other nodes first: sim:start("laptop")).
--
-- DDC: sim.ddcLatency (seconds, default 0.1) is how long an async switchTo takes; sim.ddcApply = "end"
--   (default) applies the command when it completes, "start" applies it at once and only reports later.
-- Clock: one shared fakes.timer(); sim.now() is BASE + fake seconds, in integer ms.
-- Sensors (per node name, survive restarts): sim:setLocked(name, bool), sim:setIdle(name, sec),
--   sim:setClosed(name, bool) (the lid is only known 0.05 s after start, like the real sensor) before
--   sim:start; sim:activate / lock / sleep (systemWillSleep, sync) / lid(name, closed) fire events.
-- Network: sim:partition(name, bool); sim:hello(name) makes `name` greet every started peer, like a
--   fresh Bonjour announcement; sim:restart(name, {keepOld = true}) starts a new instance of the node
--   (the old one keeps running when keepOld is set, so it can be heard again).
-- Observation: sim:input(), sim:owner(viewer), sim:presence(viewer, name), sim:node(name), sim:state(name),
--   sim.monitor (commands, applied, stuck, failing), sim.counts[name] = {switchTo, switchToSync, sendSync,
--   broadcastSync, cancel}, sim.messages (every send), sim:sent{from=,to=,type=}, sim.notifications,
--   sim:notified(kind, node), sim:ddcCalls(name) (switchTo/switchToSync calls that reached the backend of a
--   noDdc node), sim:mirrored(name) (the node mirrors the display now), sim:mirrorCalls(name) = {mirror, unmirror}
--   (calls of the fake away, cumulative over restarts), sim.logLines ("<node> <level> <message>").

local fakes = dofile("spec/support/fakes.lua")
local State = dofile("state.lua")
local Policy = dofile("policy.lua")
local Instances = dofile("instances.lua")
local Node = dofile("node.lua")

local BASE = 1760000000000
local SOFT_TIMEOUT = 5
local DDC_LATENCY = 0.1
local LID_READ_LATENCY = 0.05

local Sim = {}
Sim.__index = Sim

local function copy(v)
  if type(v) ~= "table" then return v end
  local c = {}
  for k, x in pairs(v) do c[k] = copy(x) end
  return c
end

local function newMonitor(spec)
  local m = {
    inputs = spec.inputs,
    mode = spec.mode or "detaching",
    acceptsInactive = spec.acceptsInactive == true,
    input = spec.input,
    commands = 0,
    applied = 0,
    stuck = false,
    failing = false,
  }

  function m:visibleTo(node)
    if self.mode == "sticky" then return true end
    return self.input == self.inputs[node]
  end

  -- `node` asks the monitor to show `target`'s input. Returns whether the command was accepted.
  function m:command(node, target)
    self.commands = self.commands + 1
    if not self:visibleTo(node) then return false end
    if not (self.input == self.inputs[node] or self.acceptsInactive) then return false end
    if self.failing then return false end
    if not self.stuck then
      self.input = self.inputs[target]
      self.applied = self.applied + 1
    end
    return true
  end

  return m
end

local function newDisplay(sim, node, id, spec)
  local counts = sim.counts[node]
  local d = { id = id, pull = spec.pull, home = spec.home }

  function d:inputFor(n) return spec.inputs[n] end
  -- Fact F8: a mirrored screen disappears from the screens of the node that mirrors it.
  function d:visible() return sim.monitor:visibleTo(node) and not sim.mirroring[node] end
  function d:target()
    if not self:visible() then return nil end
    return { uuid = "UUID-" .. id, name = id }
  end

  function d:switchTo(target, done)
    counts.switchTo = counts.switchTo + 1
    if spec.inputs[target] == nil then return done(false, "unknown-node") end
    if sim.noDdc[node] then
      sim.ddcCount[node] = sim.ddcCount[node] + 1
      return sim.timer.doAfter(sim.ddcLatency, function() done(true) end)
    end
    if not self:visible() then return done(false, "not-visible") end
    local ok
    local early = sim.ddcApply == "start"
    if early then ok = sim.monitor:command(node, target) end
    sim.timer.doAfter(sim.ddcLatency, function()
      if not early then ok = sim.monitor:command(node, target) end
      if ok then done(true) else done(false, "backend-error") end
    end)
  end

  function d:cancel() counts.cancel = counts.cancel + 1 end

  function d:switchToSync(target, _)
    counts.switchToSync = counts.switchToSync + 1
    if spec.inputs[target] == nil then return false, "unknown-node" end
    if sim.noDdc[node] then
      sim.ddcCount[node] = sim.ddcCount[node] + 1
      return true
    end
    if not self:visible() then return false, "not-visible" end
    if sim.monitor:command(node, target) then return true end
    return false, "backend-error"
  end

  return d
end

-- Peers configured by address are only known by their address until a reply teaches the alias.
local function newResolver(sim, entry)
  return function(peer)
    local byAddress = sim.addressOwner[peer]
    if byAddress then return sim.routes[byAddress] end
    if sim.static[peer] and entry.aliases[peer] == nil then return nil end
    return sim.routes[peer]
  end
end

local function newTransport(sim, entry)
  local name = entry.name
  local counts = sim.counts[name]
  local t = {}

  local resolve = entry.resolve

  local function reachable(target)
    return target ~= nil and target.listening and not sim.partitioned[name] and not sim.partitioned[target.name]
  end

  local function envelope(msgType, body)
    return { type = msgType, from = name, instance = entry.instance, ts = sim.now(), body = copy(body) }
  end

  function t:start(onMessage, onSeen)
    entry.onMessage, entry.onSeen, entry.listening = onMessage, onSeen, true
  end

  function t:stop() entry.listening = false end

  function t:send(peer, msgType, body, cb)
    sim:_record(name, peer, msgType, body, false)
    local lat = sim.latency
    local function fail(delay, status) sim.timer.doAfter(delay, function() cb(false, nil, status) end) end

    if resolve(peer) == nil then return fail(0, "unknown-peer") end
    if not reachable(resolve(peer)) then
      if sim.partitionMode == "timeout" then return fail(SOFT_TIMEOUT, "timeout") end
      return fail(0, "unreachable")
    end

    local msg = envelope(msgType, body)
    sim.timer.doAfter(lat, function()
      local target = resolve(peer)
      if not reachable(target) then return fail(SOFT_TIMEOUT - lat, "timeout") end
      local status, reply = target.onMessage(copy(msg))
      sim.timer.doAfter(lat, function()
        if not reachable(resolve(peer)) then return cb(false, nil, "timeout") end
        if status == 200 and reply ~= nil then
          if sim.addressOwner[peer] then entry.aliases[target.name] = peer end
          entry.onSeen(target.name)
          cb(true, copy(reply), 200)
        elseif status == 204 then
          cb(true, nil, 204)
        else
          cb(false, nil, status)
        end
      end)
    end)
  end

  function t:sendSync(peer, msgType, body, _)
    counts.sendSync = counts.sendSync + 1
    sim:_record(name, peer, msgType, body, true)
    local target = resolve(peer)
    if not reachable(target) then return false end
    local status = target.onMessage(envelope(msgType, body))
    return status == 200 or status == 204
  end

  function t:broadcastSync(msgType, body, timeoutSec)
    counts.broadcastSync = counts.broadcastSync + 1
    local n = 0
    for _, peer in ipairs(entry.discovery:names()) do
      if self:sendSync(peer, msgType, body, timeoutSec) then n = n + 1 end
    end
    return n
  end

  return t
end

local function newDiscovery(sim, entry)
  local d = {}

  function d:names()
    local out = {}
    if sim.mute[entry.name] then return out end
    for _, name in ipairs(sim.names) do
      local other = sim.routes[name]
      if name ~= entry.name then
        -- Static addresses are always listed, up or not; Bonjour peers only while they are running.
        if sim.static[name] then
          out[#out + 1] = sim.static[name]
        elseif other and other.listening then
          out[#out + 1] = name
        end
      end
    end
    table.sort(out)
    return out
  end

  -- Like the real Discovery: Bonjour peers that are already running are found, every static
  -- address is announced once, whether or not anything listens there yet.
  function d:start(onUp, _)
    entry.onUp, entry.discoveryStarted = onUp, true
    for _, name in ipairs(self:names()) do
      if sim.addressOwner[name] or sim.routes[name] then onUp(name) end
    end
  end

  function d:stop() entry.discoveryStarted = false end
  function d:resolve(name) return entry.resolve(name) and { host = name, port = 0 } or nil end
  function d:alias(node, address) entry.aliases[node] = address end

  -- Static addresses with no alias leading to a node that is alive.
  function d:unaliased(isAlive)
    local out = {}
    for _, address in ipairs(self:names()) do
      if sim.addressOwner[address] then
        local learned = false
        for node, aliased in pairs(entry.aliases) do
          if aliased == address and isAlive(node) then learned = true end
        end
        if not learned then out[#out + 1] = address end
      end
    end
    return out
  end

  return d
end

function Sim:_record(from, to, msgType, body, sync)
  self.messages[#self.messages + 1] = {
    at = self.now(), from = from, to = to, type = msgType, body = copy(body), sync = sync,
  }
end

function Sim:_build(name)
  local sensors = self.sensors[name]
  local entry = { name = name, aliases = {} }
  self.instanceCounter = self.instanceCounter + 1
  entry.instance = name .. "-instance-" .. self.instanceCounter
  entry.state = State.new()

  local displaySpec = {
    inputs = self.monitor.inputs, home = self.home, pull = self.pull, match = self.displayId,
    control = self.control, whenAway = self.whenAway, mirrorTo = self.mirrorTo,
  }
  local cfg = {
    node = name,
    heartbeat = self.heartbeat,
    activity = { userIdle = 5, startIdle = 30, lid = self.lidEnabled },
    displays = { [self.displayId] = displaySpec },
  }

  -- The fake `away`: mirroring flips sim.mirroring[name] (which hides the display from that node).
  local away = {}
  function away.mirror(_, sourceUuid, targetUuid)
    self.mirrorCount[name].mirror = self.mirrorCount[name].mirror + 1
    if self.mirrorFails[name] then return false end
    assert(sourceUuid == "UUID-" .. self.displayId, "mirror of an unexpected screen: " .. tostring(sourceUuid))
    self.mirroring[name] = true
    return true, targetUuid or "UUID-primary"
  end
  function away.defaultTarget(_, _) return "UUID-primary" end
  function away.unmirror(_, _)
    self.mirrorCount[name].unmirror = self.mirrorCount[name].unmirror + 1
    if self.unmirrorFails[name] then return false end
    self.mirroring[name] = false
    return true
  end

  entry.resolve = newResolver(self, entry)
  entry.transport = newTransport(self, entry)
  entry.discovery = newDiscovery(self, entry)

  local activity = {}
  function activity.start(_, onChange) entry.onActivity = onChange end
  function activity.stop() entry.onActivity = nil end
  function activity.isLocked() return sensors.locked end
  function activity.initial()
    if not sensors.locked and sensors.idle < 30 then return true, "start" end
    return false, "start (idle)"
  end

  -- Like the real sensor: the state is unknown (nil) until the first async read completes, which then
  -- calls onReady(closed).
  local lid = {}
  function lid.start(_, onChange, onReady)
    entry.onLid, entry.lidKnown = onChange, false
    self.timer.doAfter(LID_READ_LATENCY, function()
      if entry.onLid ~= onChange then return end
      entry.lidKnown = true
      if onReady then onReady(sensors.closed) end
    end)
  end
  function lid.stop() entry.onLid = nil end
  function lid.closed()
    if entry.lidKnown then return sensors.closed end
    return nil
  end

  local log = {}
  for _, level in ipairs({ "d", "i", "w", "e" }) do
    log[level] = function(msg) self.logLines[#self.logLines + 1] = name .. " " .. level .. " " .. tostring(msg) end
  end

  entry.node = Node.new(cfg, {
    state = entry.state,
    policy = Policy,
    instances = Instances.new(2 * self.heartbeat * 1000),
    instance = entry.instance,
    displays = { [self.displayId] = newDisplay(self, name, self.displayId, displaySpec) },
    transport = entry.transport,
    discovery = entry.discovery,
    activity = activity,
    lid = lid,
    away = away,
    now = self.now,
    timer = self.timer,
    log = log,
    notify = function(kind, text)
      self.notifications[#self.notifications + 1] = { node = name, kind = kind, text = text }
    end,
  })
  self.entries[name] = entry
  return entry
end

function Sim.new(opts)
  local self = setmetatable({}, Sim)
  self.timer = fakes.timer()
  self.now = function() return BASE + math.floor(self.timer.now() * 1000 + 0.5) end
  self.names = opts.nodes
  self.home = opts.home
  self.pull = opts.pull
  if self.pull == nil then self.pull = true end
  self.displayId = opts.displayId or "left"
  self.heartbeat = opts.heartbeat or 30
  self.latency = opts.latency or 0.01
  self.partitionMode = opts.partitionMode or "unreachable"
  self.mute = opts.mute or {}
  self.static = opts.static or {}
  self.addressOwner = {}
  for node, address in pairs(self.static) do self.addressOwner[address] = node end
  self.ddcLatency = DDC_LATENCY
  self.ddcApply = "end"
  self.control = opts.monitor.control
  if self.control == nil then
    self.control = {}
    for node in pairs(opts.monitor.inputs) do self.control[#self.control + 1] = node end
    table.sort(self.control)
  end
  self.noDdc, self.ddcCount = {}, {}
  for _, node in ipairs(opts.monitor.noDdc or {}) do self.noDdc[node] = true end
  for _, node in ipairs(opts.nodes) do self.ddcCount[node] = 0 end
  self.lidEnabled = opts.lid == true
  self.whenAway, self.mirrorTo = opts.whenAway, opts.mirrorTo
  self.mirroring, self.mirrorCount, self.mirrorFails, self.unmirrorFails = {}, {}, {}, {}
  for _, node in ipairs(opts.nodes) do self.mirrorCount[node] = { mirror = 0, unmirror = 0 } end
  self.monitor = newMonitor({
    inputs = opts.monitor.inputs,
    mode = opts.monitor.mode,
    acceptsInactive = opts.monitor.acceptsInactive,
    input = opts.monitor.input or opts.monitor.inputs[opts.home],
  })
  self.partitioned, self.sensors, self.counts, self.entries, self.routes = {}, {}, {}, {}, {}
  self.retired, self.messages, self.notifications, self.logLines = {}, {}, {}, {}
  self.instanceCounter = 0
  for _, name in ipairs(self.names) do
    self.sensors[name] = { locked = true, idle = 1000, closed = false }
    self.counts[name] = { switchTo = 0, switchToSync = 0, sendSync = 0, broadcastSync = 0, cancel = 0 }
    self:_build(name)
  end
  return self
end

function Sim:_startEntry(entry)
  self.routes[entry.name] = entry
  entry.node:start()
  for _, other in pairs(self.routes) do
    -- Only Bonjour announces a node that starts later; a static address is greeted at start only.
    if other ~= entry and other.discoveryStarted and not self.mute[other.name] and not self.static[entry.name] then
      other.onUp(entry.name)
    end
  end
end

-- Starts every node, or just `name`.
function Sim:start(name)
  for _, n in ipairs(self.names) do
    if name == nil or name == n then self:_startEntry(self.entries[n]) end
  end
end

function Sim:restart(name, opts)
  local old = self.entries[name]
  if opts and opts.keepOld then
    self.retired[#self.retired + 1] = old
  else
    old.node:stop()
  end
  local entry = self:_build(name)
  self:_startEntry(entry)
  return old
end

function Sim:advance(sec) self.timer.advance(sec) end
function Sim:node(name) return self.entries[name].node end
function Sim:state(name) return self.entries[name].state end
function Sim:input() return self.monitor.input end
function Sim:owner(viewer) return (self.entries[viewer].state:owner(self.displayId)) end
function Sim:presence(viewer, name) return self.entries[viewer].state:presence(name) end
function Sim:partition(name, on) self.partitioned[name] = on end
function Sim:setLocked(name, locked) self.sensors[name].locked = locked end
function Sim:setIdle(name, sec) self.sensors[name].idle = sec end
function Sim:setClosed(name, closed) self.sensors[name].closed = closed end

function Sim:activate(name)
  local s = self.sensors[name]
  s.locked, s.idle = false, 0
  self.entries[name].onActivity(true, "screensDidUnlock", false)
end

function Sim:lock(name)
  self.sensors[name].locked = true
  self.entries[name].onActivity(false, "screensDidLock", false)
end

function Sim:sleep(name)
  self.sensors[name].locked = true
  self.entries[name].onActivity(false, "systemWillSleep", true)
end

function Sim:lid(name, closed)
  self.sensors[name].closed = closed
  self.entries[name].onLid(closed)
end

function Sim:hello(name)
  local entry = self.entries[name]
  for _, peer in ipairs(entry.discovery:names()) do entry.onUp(peer) end
end

-- Messages sent so far matching every given field of `filter` (from, to, type, sync).
function Sim:sent(filter)
  local out = {}
  for _, m in ipairs(self.messages) do
    local match = true
    for k, v in pairs(filter or {}) do
      if m[k] ~= v then match = false end
    end
    if match then out[#out + 1] = m end
  end
  return out
end

function Sim:ddcCalls(name) return self.ddcCount[name] or 0 end

-- Whether `name` mirrors the display right now, and how many times it asked to start or stop.
function Sim:mirrored(name) return self.mirroring[name] == true end
function Sim:mirrorCalls(name) return self.mirrorCount[name] end

function Sim:notified(kind, node)
  local n = 0
  for _, x in ipairs(self.notifications) do
    if x.kind == kind and (node == nil or x.node == node) then n = n + 1 end
  end
  return n
end

return Sim
