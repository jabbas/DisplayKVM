-- Node: orchestrates sensors, policy, displays and transport (design §5, §7, §10).
-- Every collaborator is injected through `deps`; this module does not touch Hammerspoon.
--   Node.new(cfg, deps)
--   deps = {state, policy, instances, instance, displays = {[id] = Display}, transport, discovery,
--           activity, lid, now = fn() -> ms, timer, log = {d, i, w, e}, notify = fn(kind, text)}

local Node = {}
Node.__index = Node

local MAX_ATTEMPTS = 5
local RETRY_DELAYS = { 2, 4, 8, 8 } -- before attempts 2..5
local VERIFY_DELAY = 3
local REQUEST_SWITCH_TIMEOUT = 3
local SLEEP_SWITCH_TIMEOUT = 2
local SLEEP_SEND_TIMEOUT = 1
local NOTIFY_INTERVAL_MS = 300000
local ALIVE_INTERVALS = 3

local WIRE_REASONS = {
  ["not-visible"] = "not-visible",
  ["backend-error"] = "backend-error",
  ["unknown-node"] = "unknown-display",
}

local noop = function() end

function Node.new(cfg, deps)
  local self = setmetatable({}, Node)
  self.cfg = cfg
  self.me = cfg.node
  self.state = deps.state
  self.policy = deps.policy
  self.instances = deps.instances
  self.instance = deps.instance
  self.displays = deps.displays
  self.transport = deps.transport
  self.discovery = deps.discovery
  self.activity = deps.activity
  self.lid = deps.lid
  self.now = deps.now
  self.timer = deps.timer
  self.log = deps.log or { d = noop, i = noop, w = noop, e = noop }
  self.notifyFn = deps.notify or noop
  self.lastSeen = {}      -- node -> ms of the last verified message from it
  self.lastNotified = {}  -- kind -> ms
  self.intents = {}       -- display id -> claim intent
  self.releasing = {}     -- display id -> true while an async release switch is in flight
  self.active = false
  self.lidClosed = false
  self.running = false
  return self
end

-- ---------------------------------------------------------------- liveness and notifications

function Node:alive(name)
  local t = self.lastSeen[name]
  return t ~= nil and self.now() - t <= ALIVE_INTERVALS * self.cfg.heartbeat * 1000
end

function Node:_seen(from)
  self.lastSeen[from] = self.now()
  self.lastSeenFrom = from
end

function Node:_notify(kind, text)
  local now = self.now()
  local last = self.lastNotified[kind]
  if last ~= nil and now - last < NOTIFY_INTERVAL_MS then
    self.log.d("notification '" .. kind .. "' suppressed (rate limit)")
    return
  end
  self.lastNotified[kind] = now
  self.notifyFn(kind, text)
end

-- ---------------------------------------------------------------- state writes and broadcast

-- Own presence: ts = max(now, previous ts + 1); `since` only changes on a transition.
function Node:_setPresence(active)
  local prev = self.state:presence(self.me)
  if prev and prev.active == active then return false end
  local ts = self.now()
  if prev and prev.ts + 1 > ts then ts = prev.ts + 1 end
  return self.state:setPresence(self.me, active, ts, ts)
end

-- Owner write. A record that already names this node is superseded, never tied.
function Node:_writeOwner(id, node)
  local ts = self.now()
  local current, currentTs = self.state:owner(id)
  if current == self.me and currentTs >= ts then ts = currentTs + 1 end
  return self.state:setOwner(id, node, ts)
end

function Node:_stateBody()
  return { state = self.state:snapshot() }
end

function Node:_broadcast()
  local body = self:_stateBody()
  for _, name in ipairs(self.discovery:names()) do
    self.transport:send(name, "state", body, function(ok, _, status)
      if not ok then self.log.d("state to " .. tostring(name) .. " failed: " .. tostring(status)) end
    end)
  end
end

-- Sleep path: blocking sends, alive peers only (a dead peer would block the whole wake-up).
function Node:_broadcastSync()
  local body = self:_stateBody()
  for _, name in ipairs(self.discovery:names()) do
    if self:alive(name) then
      self.transport:sendSync(name, "state", body, SLEEP_SEND_TIMEOUT)
    end
  end
end

-- ---------------------------------------------------------------- claiming

function Node:_live(intent)
  return self.running and self.active and self.intents[intent.id] == intent
end

function Node:_cancelIntent(id)
  local intent = self.intents[id]
  if not intent then return end
  if intent.timer then intent.timer:stop() end
  if intent.verify then intent.verify:stop() end
  self.intents[id] = nil
end

function Node:_cancelIntents()
  for id in pairs(self.intents) do self:_cancelIntent(id) end
end

function Node:_startClaim(id)
  self:_cancelIntent(id)
  local intent = { id = id, attempts = 0 }
  self.intents[id] = intent
  self:_attempt(intent)
end

-- Alive peers that take part in the display, minus `skip`, sorted by name.
function Node:_requestTargets(id, skip)
  local display = self.displays[id]
  local out = {}
  for name in pairs(self.lastSeen) do
    if name ~= self.me and name ~= skip and self:alive(name) and display:inputFor(name) ~= nil then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

-- Sends `request` to every target at once; cb(true) on the first ok, cb(false) when all failed.
function Node:_ask(intent, targets, cb)
  local pending, settled = #targets, false
  for _, peer in ipairs(targets) do
    self.transport:send(peer, "request", { display = intent.id, to = self.me }, function(ok, reply, status)
      if settled or not self:_live(intent) then return end
      pending = pending - 1
      if ok and type(reply) == "table" and reply.result == "ok" then
        settled = true
        return cb(true)
      end
      local why = type(reply) == "table" and reply.reason or status
      self.log.d("request to " .. tostring(peer) .. " for " .. intent.id .. " failed: " .. tostring(why))
      if pending == 0 then
        settled = true
        cb(false)
      end
    end)
  end
end

-- One attempt (counted): pull, request to the recorded owner, or request to every alive peer.
function Node:_attempt(intent)
  if not self:_live(intent) then return end
  if intent.attempts >= MAX_ATTEMPTS then return self:_exhausted(intent) end
  intent.attempts = intent.attempts + 1

  local id = intent.id
  local display = self.displays[id]
  if display:visible() and display.pull ~= false then
    display:switchTo(self.me, function(ok, reason)
      if not self:_live(intent) then return end
      if ok then return self:_claimed(intent, false) end
      self.log.w("pull of " .. id .. " failed: " .. tostring(reason))
      self:_retry(intent)
    end)
    return
  end

  local owner = self.state:owner(id)
  if owner ~= nil and owner ~= self.me and self:alive(owner) and display:inputFor(owner) ~= nil then
    self:_ask(intent, { owner }, function(ok)
      if ok then return self:_claimed(intent, true) end
      self:_fallback(intent, owner)
    end)
    return
  end
  self:_broadcastRequest(intent, nil)
end

function Node:_broadcastRequest(intent, skip)
  local targets = self:_requestTargets(intent.id, skip)
  if #targets == 0 then
    self.log.d("no alive peer to ask for " .. intent.id)
    return self:_retry(intent)
  end
  self:_ask(intent, targets, function(ok)
    if ok then return self:_claimed(intent, true) end
    self:_retry(intent)
  end)
end

-- The owner did not deliver: ask everyone else. This is an attempt of its own.
function Node:_fallback(intent, owner)
  if #self:_requestTargets(intent.id, owner) == 0 or intent.attempts >= MAX_ATTEMPTS then
    return self:_retry(intent)
  end
  intent.attempts = intent.attempts + 1
  self:_broadcastRequest(intent, owner)
end

function Node:_claimed(intent, viaRequest)
  self:_writeOwner(intent.id, self.me)
  self:_broadcast()
  if not viaRequest then
    self.intents[intent.id] = nil
    return
  end
  intent.verify = self.timer.doAfter(VERIFY_DELAY, function()
    intent.verify = nil
    self:_verify(intent)
  end)
end

-- 3 s after a claim through `request`: another owner means someone won; invisible means try again.
function Node:_verify(intent)
  if not self:_live(intent) then return end
  local id = intent.id
  if self.state:owner(id) ~= self.me then
    self.log.i("claim of " .. id .. " lost to " .. tostring(self.state:owner(id)) .. ", dropping intent")
    self:_cancelIntent(id)
    return
  end
  if self.displays[id]:visible() then
    self.intents[id] = nil
    return
  end
  self.log.w("claim of " .. id .. " reported ok but the display is not visible")
  self:_retry(intent)
end

function Node:_retry(intent)
  if not self:_live(intent) then return end
  if intent.attempts >= MAX_ATTEMPTS then return self:_exhausted(intent) end
  intent.timer = self.timer.doAfter(RETRY_DELAYS[intent.attempts], function()
    intent.timer = nil
    self:_attempt(intent)
  end)
end

function Node:_exhausted(intent)
  intent.exhausted = true
  self.log.e("cannot claim " .. intent.id)
  self:_notify("claim-failed", "cannot claim " .. intent.id)
end

-- The owner of a failed claim said hello: start over with a fresh attempt counter.
function Node:_ownerReturned(node)
  local ids = {}
  for id, intent in pairs(self.intents) do
    if intent.exhausted and self.state:owner(id) == node then ids[#ids + 1] = id end
  end
  for _, id in ipairs(ids) do self:_startClaim(id) end
end

-- ---------------------------------------------------------------- activity

function Node:_markActive()
  if self.active then return end
  self.active = true
  self:_setPresence(true)
  self:_broadcast()
end

function Node:_onActive(reason)
  self.log.i("active (" .. tostring(reason) .. ")")
  self:_markActive()
  for _, id in ipairs(self.policy.onActive(self.state, self.cfg, self.me)) do
    local intent = self.intents[id]
    if intent == nil or intent.exhausted then self:_startClaim(id) end
  end
end

function Node:_onInactive(reason, sync)
  self.log.i("inactive (" .. tostring(reason) .. ")" .. (sync and " [sync]" or ""))
  self.active = false
  self:_cancelIntents()
  self:_setPresence(false)

  local alive = function(name) return self:alive(name) end
  local targets = self.policy.onInactive(self.state, self.cfg, self.me, alive)
  if sync then
    for _, t in ipairs(targets) do
      local ok, why = self.displays[t.display]:switchToSync(t.target, SLEEP_SWITCH_TIMEOUT)
      if ok then
        self:_writeOwner(t.display, t.target)
      else
        self.log.e("release of " .. t.display .. " failed: " .. tostring(why))
      end
    end
    self:_broadcastSync()
    return
  end

  self:_broadcast()
  for _, t in ipairs(targets) do
    if not self.releasing[t.display] then
      self.releasing[t.display] = true
      self.displays[t.display]:switchTo(t.target, function(ok, why)
        self.releasing[t.display] = nil
        if not self.running then return end
        if not ok then return self.log.e("release of " .. t.display .. " failed: " .. tostring(why)) end
        if self.active then return end -- became active again meanwhile; the new claim decides
        self:_writeOwner(t.display, t.target)
        self:_broadcast()
      end)
    end
  end
end

function Node:_onActivity(active, reason, sync)
  if active then
    if self.lidClosed then
      self.log.d("ignoring activity while the lid is closed")
      return
    end
    self:_onActive(reason)
  else
    self:_onInactive(reason, sync)
  end
end

function Node:_onLid(closed)
  self.lidClosed = closed
  if closed then
    self:_onInactive("lid closed", false)
  elseif not self.activity:isLocked() then
    self:_onActive("lid open")
  end
end

-- ---------------------------------------------------------------- messages

function Node:_sendHello(name)
  if not self.running then return end
  self.transport:send(name, "hello", self:_stateBody(), function(ok, reply, status)
    if not ok then return self.log.d("hello to " .. tostring(name) .. " failed: " .. tostring(status)) end
    if type(reply) == "table" then self.state:merge(reply.state) end
    if self.lastSeenFrom then self:_ownerReturned(self.lastSeenFrom) end
  end)
end

function Node:_handleRequest(body)
  local display = type(body.display) == "string" and self.displays[body.display] or nil
  if display == nil or type(body.to) ~= "string" then
    return { result = "failed", reason = "unknown-display" }
  end
  local ok, reason = display:switchToSync(body.to, REQUEST_SWITCH_TIMEOUT)
  if ok then
    self:_writeOwner(display.id, body.to)
    self:_broadcast()
    return { result = "ok" }
  end
  return { result = "failed", reason = WIRE_REASONS[reason] or "backend-error" }
end

-- Called by Transport with a verified message. Returns status, replyBody|nil.
function Node:onMessage(msg)
  local from = msg.from
  self:_seen(from)
  if self.instances:observe(from, msg.instance, self.now()) == "duplicate" then
    self:_notify("duplicate-node", "another process is using the node name '" .. tostring(from) .. "'")
  end

  local body = type(msg.body) == "table" and msg.body or {}
  if msg.type == "hello" then
    self.state:merge(body.state)
    self:_ownerReturned(from)
    return 200, self:_stateBody()
  elseif msg.type == "state" then
    self.state:merge(body.state)
    return 204, nil
  elseif msg.type == "request" then
    return 200, self:_handleRequest(body)
  end
  return 404, nil
end

-- ---------------------------------------------------------------- public API

function Node:start()
  if self.running then return end
  self.running = true
  self.transport:start(function(msg) return self:onMessage(msg) end, function(from) self:_seen(from) end)

  local useLid = self.cfg.activity ~= nil and self.cfg.activity.lid == true and self.lid ~= nil
  if useLid then self.lid:start(function(closed) self:_onLid(closed) end) end

  local active, reason = self.activity:initial()
  if useLid and self.lid:closed() == true then
    self.lidClosed = true
    active = false
  end
  self.log.i(string.format("starting as '%s', initially %s (%s)",
    self.me, active and "active" or "inactive", tostring(reason)))
  self.active = active
  self:_setPresence(active)

  self.discovery:start(function(name) self:_sendHello(name) end, function(name)
    self.log.d("peer " .. tostring(name) .. " went away")
  end)
  self.activity:start(function(isActive, why, sync) self:_onActivity(isActive, why, sync) end)
  self.heartbeat = self.timer.doEvery(self.cfg.heartbeat, function() self:_broadcast() end)

  if active then self:_onActive("start") end
end

function Node:stop()
  if not self.running then return end
  self.running = false
  if self.heartbeat then self.heartbeat:stop() self.heartbeat = nil end
  self:_cancelIntents()
  self.activity:stop()
  if self.lid then self.lid:stop() end
  self.discovery:stop()
  self.transport:stop()
end

-- Manual claim. A node that claims is active by definition. Always attempts, even if owner == me.
function Node:claim(displayId)
  local ids
  if displayId == nil then
    ids = self.policy.onActive(self.state, self.cfg, self.me)
  else
    local display = self.displays[displayId]
    if display == nil or display:inputFor(self.me) == nil then
      self.log.w("cannot claim unknown display '" .. tostring(displayId) .. "'")
      return false
    end
    ids = { displayId }
  end
  self:_markActive()
  for _, id in ipairs(ids) do self:_startClaim(id) end
  return true
end

function Node:release()
  self:_onInactive("manual release", false)
end

function Node:status()
  local names = {}
  for _, d in pairs(self.cfg.displays) do
    for node in pairs(d.inputs) do names[node] = true end
  end
  for node in pairs(self.lastSeen) do names[node] = true end
  for node in pairs(self.state:snapshot().presence) do names[node] = true end
  names[self.me] = nil

  local peers = {}
  for node in pairs(names) do
    local presence = self.state:presence(node)
    peers[node] = {
      lastSeen = self.lastSeen[node],
      active = presence and presence.active or nil,
      alive = self:alive(node),
    }
  end

  local displays = {}
  for id, display in pairs(self.displays) do
    displays[id] = { owner = self.state:owner(id), visible = display:visible(), input = display:inputFor(self.me) }
  end
  return { node = self.me, instance = self.instance, peers = peers, displays = displays }
end

return Node
