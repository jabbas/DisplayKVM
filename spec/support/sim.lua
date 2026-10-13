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
--                 input = start input (default: the home node's input)}
--   home, pull   display settings (pull defaults to true), displayId (default "left")
--   heartbeat    seconds (default 30)         latency  network one-way delay in seconds (default 0.01)
--   partitionMode "unreachable" (default): a send involving a partitioned node fails at once with
--                 status "unreachable"; "timeout": it fails after the 5 s soft timeout with "timeout".
--                 A reply lost to a partition always fails with "timeout" after the soft timeout.
--   mute         {name = true}: that node's Discovery reports no peers, so it never initiates contact
--   lid          true enables the lid sensor in the node config
--
-- Clock: one shared fakes.timer(); sim.now() is BASE + fake seconds, in integer ms.
-- Sensors (per node name, survive restarts): sim:setLocked(name, bool), sim:setIdle(name, sec) before
--   sim:start; sim:activate / lock / sleep (systemWillSleep, sync) / lid(name, closed) fire events.
-- Network: sim:partition(name, bool); sim:hello(name) makes `name` greet every started peer, like a
--   fresh Bonjour announcement; sim:restart(name, {keepOld = true}) starts a new instance of the node
--   (the old one keeps running when keepOld is set, so it can be heard again).
-- Observation: sim:input(), sim:owner(viewer), sim:presence(viewer, name), sim:node(name), sim:state(name),
--   sim.monitor (commands, applied, stuck, failing), sim.counts[name] = {switchTo, switchToSync, sendSync,
--   broadcastSync}, sim.messages (every send), sim:sent{from=,to=,type=}, sim.notifications,
--   sim:notified(kind, node).

local fakes = dofile("spec/support/fakes.lua")
local State = dofile("state.lua")
local Policy = dofile("policy.lua")
local Instances = dofile("instances.lua")
local Node = dofile("node.lua")

local BASE = 1760000000000
local SOFT_TIMEOUT = 5
local DDC_LATENCY = 0.1

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
  function d:visible() return sim.monitor:visibleTo(node) end

  function d:switchTo(target, done)
    counts.switchTo = counts.switchTo + 1
    if spec.inputs[target] == nil then return done(false, "unknown-node") end
    if not self:visible() then return done(false, "not-visible") end
    sim.timer.doAfter(DDC_LATENCY, function()
      if sim.monitor:command(node, target) then done(true) else done(false, "backend-error") end
    end)
  end

  function d:switchToSync(target, _)
    counts.switchToSync = counts.switchToSync + 1
    if spec.inputs[target] == nil then return false, "unknown-node" end
    if not self:visible() then return false, "not-visible" end
    if sim.monitor:command(node, target) then return true end
    return false, "backend-error"
  end

  return d
end

local function newTransport(sim, entry)
  local name = entry.name
  local counts = sim.counts[name]
  local t = {}

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

    if sim.routes[peer] == nil then return fail(0, "unknown-peer") end
    if not reachable(sim.routes[peer]) then
      if sim.partitionMode == "timeout" then return fail(SOFT_TIMEOUT, "timeout") end
      return fail(0, "unreachable")
    end

    local msg = envelope(msgType, body)
    sim.timer.doAfter(lat, function()
      local target = sim.routes[peer]
      if not reachable(target) then return fail(SOFT_TIMEOUT - lat, "timeout") end
      local status, reply = target.onMessage(copy(msg))
      sim.timer.doAfter(lat, function()
        if not reachable(sim.routes[peer]) then return cb(false, nil, "timeout") end
        if status == 200 and reply ~= nil then
          entry.onSeen(peer)
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
    local target = sim.routes[peer]
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
    for name, other in pairs(sim.routes) do
      if name ~= entry.name and other.listening then out[#out + 1] = name end
    end
    table.sort(out)
    return out
  end

  function d:start(onUp, _)
    entry.onUp, entry.discoveryStarted = onUp, true
    for _, name in ipairs(self:names()) do onUp(name) end
  end

  function d:stop() entry.discoveryStarted = false end
  function d:resolve(name) return sim.routes[name] and { host = name, port = 0 } or nil end
  function d:alias() end

  return d
end

function Sim:_record(from, to, msgType, body, sync)
  self.messages[#self.messages + 1] = {
    at = self.now(), from = from, to = to, type = msgType, body = copy(body), sync = sync,
  }
end

function Sim:_build(name)
  local sensors = self.sensors[name]
  local entry = { name = name }
  self.instanceCounter = self.instanceCounter + 1
  entry.instance = name .. "-instance-" .. self.instanceCounter
  entry.state = State.new()

  local displaySpec = {
    inputs = self.monitor.inputs, home = self.home, pull = self.pull, match = self.displayId,
  }
  local cfg = {
    node = name,
    heartbeat = self.heartbeat,
    activity = { userIdle = 5, startIdle = 30, lid = self.lidEnabled },
    displays = { [self.displayId] = displaySpec },
  }

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

  local lid = {}
  function lid.start(_, onChange) entry.onLid = onChange end
  function lid.stop() entry.onLid = nil end
  function lid.closed() return sensors.closed end

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
  self.lidEnabled = opts.lid == true
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
    self.counts[name] = { switchTo = 0, switchToSync = 0, sendSync = 0, broadcastSync = 0 }
    self:_build(name)
  end
  return self
end

function Sim:_startEntry(entry)
  self.routes[entry.name] = entry
  entry.node:start()
  for _, other in pairs(self.routes) do
    if other ~= entry and other.discoveryStarted and not self.mute[other.name] then other.onUp(entry.name) end
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

function Sim:notified(kind, node)
  local n = 0
  for _, x in ipairs(self.notifications) do
    if x.kind == kind and (node == nil or x.node == node) then n = n + 1 end
  end
  return n
end

return Sim
