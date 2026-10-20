-- Node: orchestrates sensors, policy, displays and transport (design §5, §7, §10).
-- Every collaborator is injected through `deps`; this module does not touch Hammerspoon.
--
--   Node.new(cfg, deps)
--
-- cfg: the validated Config table. Used fields: node (this node's name), heartbeat (seconds),
--   displays[id].inputs (read by Policy), displays[id].control (nodes that may run DDC for the display;
--   a node outside it switches through a peer inside it), displays[id].whenAway[node] ("mirror": that node
--   mirrors the display onto another screen while another node owns it), displays[id].mirrorTo[node] (uuid of
--   the screen to mirror onto), activity.lid (boolean), plus whatever Policy reads from it.
--
-- deps (all required unless marked optional):
--   state      State object (:setOwner :setPresence :owner :presence :merge :snapshot)
--   policy     the Policy module table (.onActive(state, cfg, me), .onInactive(state, cfg, me, alive))
--   instances  object with :observe(name, instance, nowMs) -> "first"|"same"|"replaced"|"duplicate"|"stale"
--              (see instances.lua; built with Instances.new(2 * heartbeat * 1000))
--   instance   string, random per start, reported by status()
--   displays   {[id] = Display}: .id .pull :inputFor(node) :visible() :switchTo(node, done(ok, reason))
--              :switchToSync(node, timeoutSec) -> ok, reason
--              :cancel() abandons the switches in flight (their done is never called); called by stop()
--   transport  Transport: :start(onMessage, onSeen) :stop() :send(peer, type, body, cb(ok, reply, status))
--              :sendSync(peer, type, body[, timeoutSec]) -> ok
--   discovery  Discovery: :start(onUp(name), onDown(name)) :stop() :names() :resolve(name)
--              :unaliased(isAlive) -> static addresses whose node name is not learned yet
--   activity   ActivitySensor: :start(onChange(active, reason, sync)) :stop() :isLocked() :initial()
--   away       optional Away (away.lua): :mirror(sourceUuid, targetUuid|nil) -> ok, usedTargetUuid
--              :unmirror(targetUuid) -> ok, :defaultTarget(excludeUuid|nil) -> uuid|nil;
--              used only for displays with cfg.displays[id].whenAway[me] == "mirror"
--   screenWatcher optional hs.screen.watcher-like: .new(fn) -> object with :start() :stop(); a screen change
--              schedules a debounced (2 s) check whether a display this node owns has disappeared (R3a).
--              Without it only the heartbeat runs that check
--   lid        optional LidSensor: :start(onChange(closed), onReady(closed|nil)) :stop() :closed(); used only if
--              cfg.activity.lid. onReady fires once, after the asynchronous first read of the lid state
--   now        function() -> integer milliseconds (also the clock for State timestamps)
--   timer      hs.timer-like: doAfter(sec, fn), doEvery(sec, fn), both returning an object with :stop()
--   log        optional {d, i, w, e} functions taking one string
--   notify     optional function(kind, text); rate limiting (1 per 300 s per kind) is done by Node

local Node = {}
Node.__index = Node

local MAX_ATTEMPTS = 5
local RETRY_DELAYS = { 2, 4, 8, 8 } -- before attempts 2..5
local VERIFY_DELAY = 3
local REQUEST_SWITCH_TIMEOUT = 3
local SLEEP_SWITCH_TIMEOUT = 2
local NOTIFY_INTERVAL_MS = 300000
local ALIVE_INTERVALS = 3
local UNALIASED_HELLO_INTERVAL_MS = 5000
local AWAY_GRACE = 5

local WIRE_REASONS = {
  ["not-visible"] = "not-visible",
  ["backend-error"] = "backend-error",
  ["unknown-node"] = "unknown-display",
  ["not-capable"] = "not-capable",
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
  self.away = deps.away
  self.screenWatcherFactory = deps.screenWatcher
  self.now = deps.now
  self.timer = deps.timer
  self.log = deps.log or { d = noop, i = noop, w = noop, e = noop }
  self.notifyFn = deps.notify or noop
  self.lastSeen = {}      -- node -> ms of the last verified message from it
  self.lastNotified = {}  -- kind -> ms
  self.intents = {}       -- display id -> claim intent
  self.releasing = {}     -- display id -> true while an async release switch is in flight
  self.mirrored = {}      -- display id -> uuid of the screen it is mirrored onto (whenAway)
  self.mirrorWarned = {}  -- display id -> owner for which a failed mirror was already warned about
  self.stopWarned = {}    -- display id -> true after a failed unmirror was warned about (reset on success)
  self.unmirroredAt = {}  -- display id -> ms when this node last stopped mirroring it (see _checkHeld)
  self.suspected = {}     -- display id -> true while `mirrored` is only a guess made at start
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
  local changed = self.state:setOwner(id, node, ts)
  self:_syncAway()
  return changed
end

-- ---------------------------------------------------------------- whenAway mirror

-- For every display with whenAway[me] == "mirror": mirrored exactly while another node owns it. Called
-- after every change of the owner records, and it acts only on a real change (a heartbeat or hello with
-- the same owner does nothing), so the mirror is never toggled in a loop.
function Node:_syncAway()
  if self.away == nil or not self.running then return end
  for id, d in pairs(self.cfg.displays) do
    if d.whenAway ~= nil and d.whenAway[self.me] == "mirror" and self.displays[id] ~= nil then
      -- A suspected mirror (see _recoverAway) is disproved by the display showing up among the screens.
      if self.suspected[id] and self.displays[id]:target() ~= nil then
        self.log.i(id .. " is among the screens, so it was not mirrored after all")
        self.suspected[id], self.mirrored[id] = nil, nil
      end
      local owner = self.state:owner(id)
      local want = owner ~= nil and owner ~= self.me
      if want and self.mirrored[id] == nil then
        self:_startMirror(id, owner, d.mirrorTo and d.mirrorTo[self.me])
      elseif not want and self.mirrored[id] ~= nil then
        -- Right after a reload the state is empty: wait to hear who owns the display instead of
        -- un-mirroring now only to mirror again when the first peer answers.
        if self.suspected[id] and owner == nil and self.awayGrace then
          self.log.d("keeping the suspected mirror of " .. id .. " until a peer has been heard")
        else
          self:_stopMirror(id)
        end
      end
    end
  end
end

-- Ends the start-up grace period (first verified state from a peer, or its timer) and applies the rule.
function Node:_awayHeard()
  if self.awayGrace then
    self.awayGrace = false
    if self.awayGraceTimer then self.awayGraceTimer:stop() self.awayGraceTimer = nil end
  end
  self:_syncAway()
end

function Node:_startMirror(id, owner, targetUuid)
  local source = self.displays[id]:target()
  if source == nil then
    return self.log.d("not mirroring " .. id .. " (owned by " .. owner .. "): display not among the screens")
  end
  local ok, used = self.away:mirror(source.uuid, targetUuid)
  if not ok then
    if self.mirrorWarned[id] ~= owner then
      self.mirrorWarned[id] = owner
      self.log.w("cannot mirror " .. id .. " (owned by " .. owner .. "), will retry on the next state change")
    end
    return
  end
  self.mirrorWarned[id] = nil
  self.mirrored[id] = used
  self.log.i("mirroring " .. id .. " (owned by " .. owner .. ")")
end

function Node:_stopMirror(id)
  if not self.away:unmirror(self.mirrored[id]) then
    if not self.stopWarned[id] then
      self.stopWarned[id] = true
      self.log.w("cannot stop mirroring " .. id .. ", will retry on the next state change")
    end
    return
  end
  self.stopWarned[id] = nil
  self.mirrored[id] = nil
  self.suspected[id] = nil
  self.unmirroredAt[id] = self.now()
  self.log.i(id .. " is back, mirror stopped")
end

-- A mirror outlives the process that made it (Hammerspoon reload without stop(), a crash): macOS stays
-- mirrored and the display is missing from the screens. At start a whenAway display that is not among the
-- screens is therefore treated as possibly mirrored by a previous run: record it, so that the first moment
-- this node wants its own screens it is un-mirrored. While another node owns the display the mirror simply
-- stays; it is not mirrored a second time. The state is empty after a reload, so an unknown owner is given
-- a grace period (AWAY_GRACE seconds, or until the first peer state arrives) before it counts as "mine".
function Node:_recoverAway()
  if self.away == nil then return end
  local suspectedAny = false
  for id, d in pairs(self.cfg.displays) do
    if d.whenAway ~= nil and d.whenAway[self.me] == "mirror" and self.displays[id] ~= nil
        and self.mirrored[id] == nil and self.displays[id]:target() == nil then
      local uuid = (d.mirrorTo and d.mirrorTo[self.me]) or self.away:defaultTarget(nil)
      if uuid ~= nil then
        self.mirrored[id] = uuid
        self.suspected[id] = true
        suspectedAny = true
        self.log.i(id .. " is not among the screens at start, assuming a mirror left by a previous run")
      end
    end
  end
  if suspectedAny then
    self.awayGrace = true
    self.awayGraceTimer = self.timer.doAfter(AWAY_GRACE, function()
      self.awayGraceTimer = nil
      if self.running then self:_awayHeard() end
    end)
  end
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

-- Static peers are only known by address. The node name behind an address is learned from the signed
-- reply to a `hello` (a `state` is answered with a bare 204), and Discovery announces a static peer
-- once, at start. So a node that started before its static peer would never be able to route to it.
-- Hence: the heartbeat sends `hello` instead of `state` to every static address without a learned
-- alias, and so does an inbound message from a node that cannot be routed yet (rate limited).
function Node:_helloUnaliased()
  local now = self.now()
  if self.lastUnaliasedHello ~= nil and now - self.lastUnaliasedHello < UNALIASED_HELLO_INTERVAL_MS then return end
  self.lastUnaliasedHello = now
  for _, address in ipairs(self.discovery:unaliased(function(name) return self:alive(name) end)) do
    self:_sendHello(address)
  end
end

-- ---------------------------------------------------------------- state recovery without DDC

local SCREEN_DEBOUNCE = 2

-- R3a. A controller that owns a display and no longer sees it has lost it: with the monitor's input
-- auto-switch (F7) it fell back to the home node, which has no DDC to be told. Record that in the state.
-- Not for a display this node mirrors itself (it is hidden by our own doing), nor while a release of the
-- display is in flight (it will write the owner by itself, and the target may not be home), nor while a
-- claim of the display is live (its verification would see the owner change under it), nor within one
-- debounce period after this node stopped mirroring it (the screen may take a moment to be listed again; the
-- check is then repeated by itself). It applies only when the home node cannot switch the display by DDC
-- itself, which is the premise of the monitor's auto-switch (F7): in a 0.1.x configuration it never fires.
-- `quiet`: the caller (the heartbeat) sends the state itself, so no broadcast here.
function Node:_checkHeld(quiet)
  if not self.running then return end
  local ids = {}
  for id in pairs(self.displays) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local home = self.cfg.displays[id].home
    local intent = self.intents[id]
    if self.state:owner(id) == self.me and home ~= nil and home ~= self.me and self:_canSwitch(id, self.me)
        and not self:_canSwitch(id, home) and (intent == nil or intent.exhausted)
        and self.mirrored[id] == nil and not self.releasing[id] and not self.displays[id]:visible() then
      local stoppedAt = self.unmirroredAt[id]
      if stoppedAt ~= nil and self.now() - stoppedAt < SCREEN_DEBOUNCE * 1000 then
        self.log.d("not checking " .. id .. " yet, the mirror was stopped just now")
        self:_onScreensChanged()
      else
        self.log.i(id .. " disappeared, assuming it switched to " .. home)
        self:_writeOwner(id, home)
        if not quiet then self:_broadcast() end
      end
    end
  end
end

-- R3b. The home node cannot run DDC. When the display's owner is gone and so is every node that could
-- switch it, the monitor has fallen back to the home input on its own: take the ownership in the state.
-- Needs no activity of this node and sends no DDC.
function Node:_recoverHome(quiet)
  if not self.running then return end
  local ids = {}
  for id in pairs(self.displays) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local owner = self.state:owner(id)
    if self.cfg.displays[id].home == self.me and not self:_canSwitch(id, self.me)
        and owner ~= nil and owner ~= self.me and not self:alive(owner) and not self:_anyControllerAlive(id) then
      self.log.i(string.format("%s: owner %s and every node with control are gone, taking ownership in the state",
        id, owner))
      self:_writeOwner(id, self.me)
      if not quiet then self:_broadcast() end
    end
  end
end

function Node:_anyControllerAlive(id)
  for name in pairs(self.lastSeen) do
    if name ~= self.me and self:alive(name) and self:_canSwitch(id, name) then return true end
  end
  return false
end

-- A screen change is followed by one check after a quiet period of SCREEN_DEBOUNCE seconds.
function Node:_onScreensChanged()
  if not self.running then return end
  if self.screenTimer then self.screenTimer:stop() end
  self.screenTimer = self.timer.doAfter(SCREEN_DEBOUNCE, function()
    self.screenTimer = nil
    self:_checkHeld()
  end)
end

function Node:_heartbeat()
  -- Any write of the checks goes out with the heartbeat state below.
  self:_checkHeld(true)
  self:_recoverHome(true)
  local body = self:_stateBody()
  local hello = {}
  for _, address in ipairs(self.discovery:unaliased(function(name) return self:alive(name) end)) do
    hello[address] = true
  end
  for _, name in ipairs(self.discovery:names()) do
    if hello[name] then
      self:_sendHello(name)
    else
      self.transport:send(name, "state", body, function(ok, _, status)
        if not ok then self.log.d("state to " .. tostring(name) .. " failed: " .. tostring(status)) end
      end)
    end
  end
end

-- Sleep path: blocking sends, alive peers only (a dead peer would block the whole wake-up). Peers are
-- addressed by node name: discovery:names() may hold bare host:port strings (static peers), whose
-- liveness is keyed by node name; Discovery:resolve maps the name back through the learned alias.
function Node:_broadcastSync()
  local body = self:_stateBody()
  local names = {}
  for name in pairs(self.lastSeen) do
    if name ~= self.me and self:alive(name) then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    self.transport:sendSync(name, "state", body)
  end
end

-- ---------------------------------------------------------------- claiming

function Node:_live(intent)
  return self.running and self.active and self.intents[intent.id] == intent
end

function Node:_cancelIntent(id, why)
  local intent = self.intents[id]
  if not intent then return end
  intent.cancelled = why
  if intent.timer then intent.timer:stop() end
  if intent.verify then intent.verify:stop() end
  self.intents[id] = nil
end

function Node:_cancelIntents(why)
  for id in pairs(self.intents) do self:_cancelIntent(id, why) end
end

function Node:_startClaim(id)
  self:_cancelIntent(id)
  local intent = { id = id, attempts = 0 }
  self.intents[id] = intent
  self:_attempt(intent)
end

-- Whether `node` may run the DDC backend for display `id`: it is listed in the display's `control`
-- (Config defaults that to every node with an input). A node outside `control` never calls the backend
-- for the display; it asks a node inside `control` instead (see _delegate).
function Node:_canSwitch(id, node)
  local control = self.cfg.displays[id].control
  if control == nil then return self.displays[id]:inputFor(node) ~= nil end
  for _, name in ipairs(control) do
    if name == node then return true end
  end
  return false
end

-- Alive peers that can switch the display, minus `skip`, sorted by name.
function Node:_requestTargets(id, skip)
  local out = {}
  for name in pairs(self.lastSeen) do
    if name ~= self.me and name ~= skip and self:alive(name) and self:_canSwitch(id, name) then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

-- Alive peers a node without DDC can hand a switch to: the recorded owner first (when it can switch),
-- then the remaining ones sorted by name.
function Node:_controlTargets(id)
  local owner = self.state:owner(id)
  local rest = self:_requestTargets(id, owner)
  if owner ~= nil and owner ~= self.me and self:alive(owner) and self:_canSwitch(id, owner) then
    table.insert(rest, 1, owner)
  end
  return rest
end

-- Switches display `id` to `target` through a capable peer: sends `request {display, to = target}` to the
-- targets of _controlTargets one after the other; the first ok wins. cb(true), or cb(false, reason, peer)
-- when there is no target ("no-controller") or all of them refused or did not answer (the reason and the
-- name of the last one).
function Node:_delegate(id, target, cb)
  local targets = self:_controlTargets(id)
  local function try(i, lastPeer, lastWhy)
    if not self.running then return end
    local peer = targets[i]
    if peer == nil then
      if lastPeer ~= nil then return cb(false, lastWhy, lastPeer) end
      self.log.d("no alive node with control to switch " .. id .. " to " .. tostring(target))
      return cb(false, "no-controller")
    end
    self.transport:send(peer, "request", { display = id, to = target }, function(ok, reply, status)
      if not self.running then return end
      if ok and type(reply) == "table" and reply.result == "ok" then return cb(true) end
      local why = type(reply) == "table" and reply.reason or status
      self.log.d("delegated switch of " .. id .. " via " .. tostring(peer) .. " failed: " .. tostring(why))
      try(i + 1, peer, why)
    end)
  end
  try(1)
end

-- Sends `request` to every target at once; cb(true) on the first ok, cb(false) when all failed.
function Node:_ask(intent, targets, cb)
  local pending, settled = #targets, false
  for _, peer in ipairs(targets) do
    self.transport:send(peer, "request", { display = intent.id, to = self.me }, function(ok, reply, status)
      if settled then return end
      local granted = ok and type(reply) == "table" and reply.result == "ok"
      if not self:_live(intent) then
        if granted then
          settled = true
          self:_lateClaim(intent)
        end
        return
      end
      pending = pending - 1
      if granted then
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
  if display:visible() and display.pull ~= false and self:_canSwitch(id, self.me) then
    display:switchTo(self.me, function(ok, reason)
      if not self:_live(intent) then
        if ok then self:_lateClaim(intent) end
        return
      end
      if ok then return self:_claimed(intent, false) end
      self.log.w("pull of " .. id .. " failed: " .. tostring(reason))
      self:_retry(intent)
    end)
    return
  end

  local owner = self.state:owner(id)
  if owner ~= nil and owner ~= self.me and self:alive(owner) and self:_canSwitch(id, owner) then
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

-- A switch that was in flight when the node went inactive has landed: the monitor now shows this
-- node although the state names someone else. Record it, then give the display back.
function Node:_lateClaim(intent)
  if intent.cancelled ~= "inactive" or not self.running or self.active then return end
  local id = intent.id
  self.log.i("claim of " .. id .. " landed after going inactive, releasing it")
  self:_writeOwner(id, self.me)
  local alive = function(name) return self:alive(name) end
  local targets = {}
  for _, t in ipairs(self.policy.onInactive(self.state, self.cfg, self.me, alive)) do
    if t.display == id then targets[#targets + 1] = t end
  end
  self:_releaseAsync(targets)
end

function Node:_claimed(intent, viaRequest)
  self:_writeOwner(intent.id, self.me)
  self:_broadcast()
  -- A node that mirrors the display while it is away (whenAway) sees it reappear only after the mirror
  -- is stopped; its visibility says nothing about the monitor, so there is nothing to verify after 3 s.
  local away = self.cfg.displays[intent.id].whenAway
  if not viaRequest or (away ~= nil and away[self.me] ~= nil) then
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
  self:_cancelIntents("inactive")
  self:_setPresence(false)

  local alive = function(name) return self:alive(name) end
  local targets = self.policy.onInactive(self.state, self.cfg, self.me, alive)
  if sync then
    local delegated = {}
    for _, t in ipairs(targets) do
      if self:_canSwitch(t.display, self.me) then
        -- Runs even when an async release of the same display is in flight: the switch to the same target
        -- is idempotent and the async one may be suspended by the sleep.
        local ok, why = self.displays[t.display]:switchToSync(t.target, SLEEP_SWITCH_TIMEOUT)
        if ok then
          self:_writeOwner(t.display, t.target)
        else
          self:_releaseFailed(t.display, why)
        end
      else
        delegated[#delegated + 1] = t
      end
    end
    self:_broadcastSync()
    -- A node without DDC hands its release to a capable peer. On the sleep path this is best effort and
    -- asynchronous (there is no blocking request/reply primitive that returns the peer's verdict): such a
    -- node is in practice a desktop that does not sleep while its owner is away. If the machine does
    -- suspend before the answer, the peer's own recovery (R3) and the next claim put the state right.
    self:_releaseAsync(delegated)
    return
  end

  self:_broadcast()
  self:_releaseAsync(targets)
end

-- A failed release is only an error when the monitor still shows this node. `not-visible` means it
-- already shows another input, and a backend failure on a display that has meanwhile disappeared means
-- another release (for example the sync one on sleep) got there first. The owner is left alone.
function Node:_releaseFailed(id, why)
  if why == "not-visible" or (why == "backend-error" and not self.displays[id]:visible()) then
    return self.log.i(id .. " already handed over (release: " .. tostring(why) .. ")")
  end
  self.log.e("release of " .. id .. " failed: " .. tostring(why))
end

-- A release handed to a capable peer did not happen: nobody with control is reachable, or the one that was
-- asked refused or did not answer. Unlike _releaseFailed, "not-visible" here is the peer's, so it says
-- nothing about this node having handed the display over. Called once per release, and releases are one in
-- flight per display, so this warns at most once per inactivity event. The owner is left alone.
function Node:_delegationFailed(id, target, why, peer)
  local prefix = "cannot hand over " .. id .. " to " .. tostring(target) .. ": "
  if why == "no-controller" then
    return self.log.w(prefix .. "no node with control is reachable")
  end
  self.log.w(prefix .. tostring(peer) .. " did not do it (" .. tostring(why) .. ")")
end

-- Asynchronous release switch: through the own backend when this node may switch the display, otherwise
-- delegated to a capable peer. done(ok, reason).
function Node:_switchAway(id, target, done)
  if self:_canSwitch(id, self.me) then return self.displays[id]:switchTo(target, done) end
  self:_delegate(id, target, done)
end

-- Async release of {display, target} pairs. At most one per display is in flight; a second inactivity
-- event meanwhile (lock, then sleep or lid close) adds nothing. When the switch lands the situation
-- may have changed: the node may be active again (claim afresh, the monitor now shows the target) or a
-- peer may have taken the display meanwhile (leave its owner record alone).
function Node:_releaseAsync(targets)
  for _, t in ipairs(targets) do
    local id = t.display
    if self.releasing[id] then
      self.log.d("release of " .. id .. " already in flight")
    else
      self.releasing[id] = true
      local delegated = not self:_canSwitch(id, self.me)
      self:_switchAway(id, t.target, function(ok, why, peer)
        self.releasing[id] = nil
        if not self.running then return end
        if not ok then
          if delegated then return self:_delegationFailed(id, t.target, why, peer) end
          return self:_releaseFailed(id, why)
        end
        if self.active then return self:_startClaim(id) end
        local owner = self.state:owner(id)
        if owner == t.target then return end -- the controller's broadcast got here before its reply
        if owner ~= self.me then
          return self.log.i("release of " .. id .. " landed but " .. tostring(owner) .. " owns it now")
        end
        self:_writeOwner(id, t.target)
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

-- The first (asynchronous) lid read is done: a lid found closed at start counts as a lid close.
function Node:_onLidReady(closed)
  if not self.running or closed ~= true or self.lidClosed then return end
  self.lidClosed = true
  if self.active then self:_onInactive("lid closed (start)", false) end
end

-- ---------------------------------------------------------------- messages

function Node:_sendHello(name)
  if not self.running then return end
  self.transport:send(name, "hello", self:_stateBody(), function(ok, reply, status)
    if not ok then return self.log.d("hello to " .. tostring(name) .. " failed: " .. tostring(status)) end
    if type(reply) == "table" then
      self.state:merge(reply.state)
      self:_awayHeard()
    end
    if self.lastSeenFrom then self:_ownerReturned(self.lastSeenFrom) end
  end)
end

function Node:_handleRequest(body)
  local display = type(body.display) == "string" and self.displays[body.display] or nil
  if display == nil or type(body.to) ~= "string" then
    return { result = "failed", reason = "unknown-display" }
  end
  -- A node outside `control` never runs the backend, not even for a request from a 0.1.x peer that
  -- does not know about `control` and addressed this node as the current owner.
  if not self:_canSwitch(display.id, self.me) then
    self.log.d("refusing request for " .. display.id .. ": not in control")
    return { result = "failed", reason = "not-capable" }
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

  if self.discovery:resolve(from) == nil then self:_helloUnaliased() end

  local body = type(msg.body) == "table" and msg.body or {}
  if msg.type == "hello" then
    self.state:merge(body.state)
    self:_awayHeard()
    self:_ownerReturned(from)
    return 200, self:_stateBody()
  elseif msg.type == "state" then
    self.state:merge(body.state)
    self:_awayHeard()
    return 204, nil
  elseif msg.type == "request" then
    return 200, self:_handleRequest(body)
  end
  return 404, nil
end

-- ---------------------------------------------------------------- public API

-- Returns true, or false and a reason when the transport cannot listen (nothing is left running).
function Node:start()
  if self.running then return true end
  local listening, startFailure = self.transport:start(function(msg) return self:onMessage(msg) end,
    function(from) self:_seen(from) end)
  if listening == false then return false, startFailure end
  self.running = true
  self:_recoverAway()

  local useLid = self.cfg.activity ~= nil and self.cfg.activity.lid == true and self.lid ~= nil
  if useLid then
    self.lid:start(function(closed) self:_onLid(closed) end, function(closed) self:_onLidReady(closed) end)
  end

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
  self.heartbeat = self.timer.doEvery(self.cfg.heartbeat, function() self:_heartbeat() end)
  if self.screenWatcherFactory ~= nil then
    self.screens = self.screenWatcherFactory.new(function() self:_onScreensChanged() end)
    self.screens:start()
  end

  if active then self:_onActive("start") end
  self:_syncAway()
  return true
end

function Node:stop()
  if not self.running then return end
  self.running = false
  if self.heartbeat then self.heartbeat:stop() self.heartbeat = nil end
  if self.screens then self.screens:stop() self.screens = nil end
  if self.screenTimer then self.screenTimer:stop() self.screenTimer = nil end
  self:_cancelIntents()
  -- Leave nothing mirrored behind: the display must be back for whoever runs next (or for the user).
  if self.awayGraceTimer then self.awayGraceTimer:stop() self.awayGraceTimer = nil end
  self.awayGrace = false
  if self.away ~= nil then
    local ids = {}
    for id in pairs(self.mirrored) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do self:_stopMirror(id) end
  end
  for _, display in pairs(self.displays) do display:cancel() end
  self.releasing = {}
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
      active = presence and presence.active, -- false when inactive, nil when never heard of
      alive = self:alive(node),
    }
  end

  local displays = {}
  for id, display in pairs(self.displays) do
    -- Same fallback as _canSwitch: without `control` every node with an input may switch.
    local control = {}
    local list = self.cfg.displays[id].control
    if list == nil then
      list = {}
      for name in pairs(self.cfg.displays[id].inputs) do list[#list + 1] = name end
      table.sort(list)
    end
    for i, name in ipairs(list) do control[i] = name end
    displays[id] = {
      owner = self.state:owner(id), visible = display:visible(), input = display:inputFor(self.me), control = control,
      mirrored = self.mirrored[id] ~= nil,
    }
  end
  return { node = self.me, instance = self.instance, peers = peers, displays = displays }
end

return Node
