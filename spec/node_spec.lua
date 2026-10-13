local Sim = dofile("spec/support/sim.lua")

local ALL_INPUTS = { ["desk-mini"] = 15, laptop = 16, studio = 17 }

-- Builds and starts a simulated group. Every node starts locked, so nobody claims yet.
local function make(o)
  o = o or {}
  local nodes = o.nodes or { "desk-mini", "laptop" }
  local inputs = {}
  for _, n in ipairs(nodes) do inputs[n] = ALL_INPUTS[n] end
  local sim = Sim.new({
    nodes = nodes,
    home = "desk-mini",
    pull = o.pull,
    mute = o.mute,
    lid = o.lid,
    static = o.static,
    partitionMode = o.partitionMode,
    monitor = { inputs = inputs, mode = o.mode, acceptsInactive = o.acceptsInactive, input = o.input },
  })
  if not o.delayed then
    sim:start()
    sim:advance(1)
  end
  return sim
end

local function requests(sim, from) return #sim:sent({ from = from, type = "request" }) end

local function allOwners(sim, nodes, expected)
  for _, n in ipairs(nodes) do assert.equal(expected, sim:owner(n), "owner as seen by " .. n) end
end

describe("Node scenarios", function()
  it("S1 unlocking the laptop moves the display to it and everyone agrees on the owner", function()
    local sim = make()
    assert.equal(15, sim:input())
    sim:activate("laptop")
    sim:advance(1)
    assert.equal(16, sim:input())
    allOwners(sim, { "desk-mini", "laptop" }, "laptop")
  end)

  it("S2 locking the laptop hands the display back to home", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    sim:lock("laptop")
    sim:advance(1)
    assert.equal(15, sim:input())
    allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
  end)

  it("S3 the desk-mini cannot see the display, so it requests it from the laptop", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    sim:activate("desk-mini")
    sim:advance(1)
    assert.equal(15, sim:input())
    allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
    assert.equal(1, requests(sim, "desk-mini"))
    assert.equal("laptop", sim:sent({ from = "desk-mini", type = "request" })[1].to)
  end)

  describe("S4 start", function()
    it("S4 an active start claims even when the state already says owner == me (pull)", function()
      local sim = make({ mode = "sticky", acceptsInactive = true })
      sim:activate("laptop")
      sim:advance(1)
      assert.equal("laptop", sim:owner("laptop"))
      local before = sim.counts.laptop.switchTo
      sim:restart("laptop")
      sim:advance(1)
      assert.equal("laptop", sim:owner("desk-mini"))
      assert.equal(before + 1, sim.counts.laptop.switchTo)
    end)

    it("S4 an active start claims even when the state already says owner == me (request)", function()
      local sim = make()
      sim:activate("laptop")
      sim:advance(1)
      sim.monitor.input = 15 -- the monitor changed input on its own
      local before = sim.monitor.commands
      sim:restart("laptop")
      sim:advance(10)
      assert.equal("laptop", sim:owner("laptop"))
      assert.is_true(sim.monitor.commands > before)
      assert.equal(16, sim:input())
    end)

    it("S4 an idle start does not claim and learns the owner from hello", function()
      local sim = make()
      sim:activate("laptop")
      sim:advance(1)
      local before = sim.monitor.commands
      sim:setIdle("laptop", 100)
      sim:restart("laptop")
      sim:advance(10)
      assert.equal(before, sim.monitor.commands)
      assert.equal("laptop", sim:owner("laptop"))
      assert.is_false(sim:presence("laptop", "laptop").active)
    end)
  end)

  it("S4b two presence transitions in the same millisecond get consecutive timestamps", function()
    local sim = make()
    sim:activate("laptop")
    local first = sim:presence("laptop", "laptop")
    sim:lock("laptop")
    local second = sim:presence("laptop", "laptop")
    assert.is_true(first.active)
    assert.is_false(second.active)
    assert.equal(first.ts + 1, second.ts)
    sim:advance(1)
    local seen = sim:presence("desk-mini", "laptop")
    assert.is_false(seen.active)
    assert.equal(second.ts, seen.ts)
  end)

  describe("S5 three nodes", function()
    it("S5 the last active other node gets the display back", function()
      local sim = make({ nodes = { "desk-mini", "laptop", "studio" } })
      sim:activate("laptop")
      sim:advance(1)
      sim:activate("studio")
      sim:advance(1)
      assert.equal(17, sim:input())
      allOwners(sim, { "desk-mini", "laptop", "studio" }, "studio")
      sim:lock("studio")
      sim:advance(1)
      assert.equal(16, sim:input())
      allOwners(sim, { "desk-mini", "laptop", "studio" }, "laptop")
    end)

    it("S5 with nobody else active the display goes home", function()
      local sim = make({ nodes = { "desk-mini", "laptop", "studio" } })
      sim:activate("laptop")
      sim:advance(1)
      sim:lock("laptop")
      sim:advance(1)
      sim:activate("studio")
      sim:advance(1)
      assert.equal(17, sim:input())
      sim:lock("studio")
      sim:advance(1)
      assert.equal(15, sim:input())
      allOwners(sim, { "desk-mini", "laptop", "studio" }, "desk-mini")
    end)
  end)

  describe("S6 unreachable owner", function()
    it("S6 retries after 2, 4, 8, 8 s, notifies once, and resumes when the owner says hello", function()
      local sim = make()
      sim:activate("laptop")
      sim:advance(1)
      sim:partition("laptop", true)
      sim:activate("desk-mini")
      local function asked() return #sim:sent({ from = "desk-mini", type = "request", to = "laptop" }) end

      sim:advance(0.5)
      assert.equal(1, asked())
      sim:advance(2) -- t = 2.5 s
      assert.equal(2, asked())
      sim:advance(4) -- t = 6.5 s
      assert.equal(3, asked())
      sim:advance(8) -- t = 14.5 s
      assert.equal(4, asked())
      assert.equal(0, sim:notified("claim-failed"))
      sim:advance(8) -- t = 22.5 s
      assert.equal(5, asked())
      assert.equal(1, sim:notified("claim-failed", "desk-mini"))
      sim:advance(100)
      assert.equal(5, asked())
      assert.equal(1, sim:notified("claim-failed"))
      assert.equal(16, sim:input())

      sim:partition("laptop", false)
      sim:hello("laptop")
      sim:advance(2)
      assert.equal(15, sim:input())
      allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
    end)

    it("S6 in timeout mode each failed request takes the 5 s soft timeout", function()
      local sim = make({ partitionMode = "timeout" })
      sim:activate("laptop")
      sim:advance(1)
      sim:partition("laptop", true)
      sim:activate("desk-mini")
      sim:advance(6)
      assert.equal(1, #sim:sent({ from = "desk-mini", type = "request" }))
      sim:advance(2) -- 5 s timeout + 2 s delay
      assert.equal(2, #sim:sent({ from = "desk-mini", type = "request" }))
    end)
  end)

  describe("S7 simultaneous claims", function()
    it("S7 converge on one owner and the loser stops sending requests after verification", function()
      local sim = make({ nodes = { "desk-mini", "laptop", "studio" } })
      sim:activate("laptop")
      sim:advance(1)
      sim:activate("desk-mini")
      sim:activate("studio")
      sim:advance(1)
      local deskRequests = requests(sim, "desk-mini")
      assert.equal(1, deskRequests)
      sim:advance(60)
      assert.equal(deskRequests, requests(sim, "desk-mini"))
      assert.equal(17, sim:input())
      allOwners(sim, { "desk-mini", "laptop", "studio" }, "studio")
    end)
  end)

  describe("S7b verification", function()
    it("S7b a request that reports ok but never shows the display is retried at most 5 times", function()
      local sim = make()
      sim.monitor.stuck = true
      sim:activate("laptop")
      sim:advance(60)
      assert.equal(5, requests(sim, "laptop"))
      assert.equal(1, sim:notified("claim-failed", "laptop"))
      sim:advance(200)
      assert.equal(5, requests(sim, "laptop"))
      assert.equal(1, sim:notified("claim-failed"))
    end)
  end)

  it("S7c the pusher records the requester as owner even when the reply is lost", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    sim:activate("desk-mini")
    sim:advance(0.015) -- the request has been handled, the reply is still in flight
    sim:partition("desk-mini", true)
    sim:advance(1) -- before the claimer's retry, which would find the display visible and pull it
    assert.equal(15, sim:input())
    assert.equal("desk-mini", sim:owner("laptop"))
    assert.equal("laptop", sim:owner("desk-mini"))
  end)

  it("S8 a sticky display that accepts commands from an inactive input is claimed by pull", function()
    local sim = make({ mode = "sticky", acceptsInactive = true })
    sim:activate("laptop")
    sim:advance(1)
    assert.equal(16, sim:input())
    assert.equal(0, #sim:sent({ type = "request" }))
    assert.equal(1, sim.counts.laptop.switchTo)
    allOwners(sim, { "desk-mini", "laptop" }, "laptop")
  end)

  it("S9 pull = false always asks the owner, even on a sticky display", function()
    local sim = make({ mode = "sticky", pull = false })
    sim:activate("laptop")
    sim:advance(1)
    assert.equal(16, sim:input())
    assert.equal(1, requests(sim, "laptop"))
    assert.equal(0, sim.counts.laptop.switchTo)
    sim:activate("desk-mini")
    sim:advance(1)
    assert.equal(15, sim:input())
    assert.equal(1, requests(sim, "desk-mini"))
    assert.equal("laptop", sim:sent({ from = "desk-mini", type = "request" })[1].to)
    assert.equal(0, sim.counts["desk-mini"].switchTo)
  end)

  it("S10 going to sleep switches and broadcasts synchronously", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    local counts = sim.counts.laptop
    local asyncBefore = counts.switchTo
    sim:sleep("laptop")
    -- no advance: everything must already be done
    assert.equal(1, counts.switchToSync)
    assert.equal(asyncBefore, counts.switchTo)
    assert.is_true(counts.sendSync >= 1)
    assert.equal(15, sim:input())
    assert.equal("desk-mini", sim:owner("laptop"))
    assert.equal("desk-mini", sim:owner("desk-mini"))
    assert.is_false(sim:presence("desk-mini", "laptop").active)
  end)

  it("S11 a restarted node replaces its old instance silently; the old one heard later raises one alarm", function()
    local sim = make()
    sim:advance(34) -- 5 s after the heartbeat at t = 30
    sim:restart("laptop", { keepOld = true })
    sim:advance(1)
    assert.equal(0, sim:notified("duplicate-node"))
    sim:advance(30) -- the old instance's heartbeat at t = 60
    assert.equal(1, sim:notified("duplicate-node", "desk-mini"))
    sim:advance(30) -- and again at t = 90: rate limited
    assert.equal(1, sim:notified("duplicate-node"))
  end)

  it("S12 an owner that no node knows leads to the fallback request to every alive peer", function()
    local sim = make()
    sim:state("laptop"):setOwner("left", "ghost", sim.now())
    sim:activate("laptop")
    sim:advance(1)
    assert.equal(0, #sim:sent({ from = "laptop", type = "request", to = "ghost" }))
    assert.equal(1, #sim:sent({ from = "laptop", type = "request", to = "desk-mini" }))
    assert.equal(16, sim:input())
    allOwners(sim, { "desk-mini", "laptop" }, "laptop")
  end)

  it("S13 claim-failed notifications are limited to one per 300 s", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    sim:partition("laptop", true)
    sim:activate("desk-mini")
    sim:advance(30)
    assert.equal(1, sim:notified("claim-failed"))
    sim:lock("desk-mini")
    sim:activate("desk-mini")
    sim:advance(30)
    assert.equal(1, sim:notified("claim-failed"))
    sim:advance(300)
    sim:lock("desk-mini")
    sim:activate("desk-mini")
    sim:advance(30)
    assert.equal(2, sim:notified("claim-failed"))
  end)

  it("S14 status lists peers with liveness, the owner and local visibility", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    local st = sim:node("desk-mini"):status()
    assert.equal("desk-mini", st.node)
    assert.is_string(st.instance)
    assert.is_true(st.peers.laptop.alive)
    assert.is_true(st.peers.laptop.active)
    assert.is_number(st.peers.laptop.lastSeen)
    assert.equal("laptop", st.displays.left.owner)
    assert.is_false(st.displays.left.visible)
    assert.equal(15, st.displays.left.input)
    assert.is_true(sim:node("laptop"):status().displays.left.visible)

    sim:partition("laptop", true)
    sim:advance(100)
    assert.is_false(sim:node("desk-mini"):status().peers.laptop.alive)
  end)

  it("S14b status shows a peer that is inactive as active = false, and one never heard of as nil", function()
    local sim = make({ nodes = { "desk-mini", "laptop", "studio" }, delayed = true })
    sim:start("desk-mini")
    sim:start("laptop")
    sim:advance(1)
    sim:activate("laptop")
    sim:advance(1)
    sim:lock("laptop")
    sim:advance(1)
    local peers = sim:node("desk-mini"):status().peers
    assert.is_false(peers.laptop.active)
    assert.is_nil(peers.studio.active)
  end)

  it("S15 a peer that only ever replies is alive, because replies count as contact", function()
    local sim = make({ mute = { laptop = true } })
    assert.equal(0, #sim:sent({ from = "laptop" }))
    local st = sim:node("desk-mini"):status()
    assert.is_true(st.peers.laptop.alive)
    assert.is_true(sim:node("desk-mini"):alive("laptop"))
  end)

  describe("in-flight switches racing with lock and unlock", function()
    local function allAgree(sim, expectedInput, expectedOwner)
      assert.equal(expectedInput, sim:input())
      allOwners(sim, { "desk-mini", "laptop" }, expectedOwner)
    end

    it("R1a a lock right after an unlock hands the display back (request path)", function()
      local sim = make()
      sim:activate("laptop")
      sim:lock("laptop") -- no advance: the request is still in flight
      sim:advance(5)
      allAgree(sim, 15, "desk-mini")
    end)

    it("R1a a lock right after an unlock hands the display back (pull path)", function()
      local sim = make({ mode = "sticky", acceptsInactive = true })
      sim:activate("laptop")
      sim:lock("laptop") -- the pull is still in flight
      sim:advance(5)
      allAgree(sim, 15, "desk-mini")
    end)

    it("R1b an unlock while the release is still in flight claims again afterwards", function()
      local sim = make()
      sim:activate("laptop")
      sim:advance(1)
      sim.ddcLatency = 0.3
      sim:lock("laptop") -- the release lands at +0.3 s
      sim.ddcLatency = 0.05
      sim:activate("laptop") -- the pull lands first, the release after it
      sim:advance(10)
      allAgree(sim, 16, "laptop")
    end)

    it("R1c a request pushed during an async release is not overwritten by the release", function()
      local sim = make({
        nodes = { "desk-mini", "laptop", "studio" }, mode = "sticky", acceptsInactive = true, pull = false,
      })
      sim:activate("laptop")
      sim:advance(1)
      assert.equal(16, sim:input())
      sim.ddcApply = "start"
      sim.ddcLatency = 0.3
      sim:lock("laptop") -- the release command is sent now, its completion arrives at +0.3 s
      sim:activate("studio") -- studio asks the laptop meanwhile
      sim:advance(10)
      assert.equal(17, sim:input())
      allOwners(sim, { "desk-mini", "laptop", "studio" }, "studio")
    end)
  end)

  it("S16 releasing to a home that is not alive still switches and records the owner", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    sim:partition("desk-mini", true)
    sim:advance(100)
    assert.is_false(sim:node("laptop"):alive("desk-mini"))
    sim:lock("laptop")
    sim:advance(1)
    assert.equal(15, sim:input())
    assert.equal("desk-mini", sim:owner("laptop"))
  end)
end)

describe("Node sleep broadcast with static peers", function()
  it("S10b reaches a peer known only by address, through the alias learned from its hello reply", function()
    local sim = make({ static = { ["desk-mini"] = "192.0.2.1:8765" } })
    assert.same({ "192.0.2.1:8765" }, sim.entries.laptop.discovery:names())
    sim:activate("laptop")
    sim:advance(1)
    sim:sleep("laptop") -- no advance
    assert.equal(1, #sim:sent({ from = "laptop", to = "desk-mini", sync = true }))
    assert.equal("desk-mini", sim:owner("desk-mini"))
    assert.is_false(sim:presence("desk-mini", "laptop").active)
  end)

  describe("S10c the peer that starts later (static peers only)", function()
    local STATIC = { ["desk-mini"] = "192.0.2.1:8765", laptop = "192.0.2.2:8765" }

    -- laptop is up first; desk-mini starts afterwards. Real Discovery never announces a late
    -- static peer to a node that is already running.
    local function reverseStart()
      local sim = make({ static = STATIC, delayed = true })
      sim:start("laptop")
      sim:advance(1)
      sim:start("desk-mini")
      sim:advance(1)
      return sim
    end

    it("lets the node that started first request the display from the late peer", function()
      local sim = reverseStart()
      assert.is_true(sim:node("laptop"):alive("desk-mini"))
      sim:activate("laptop")
      sim:advance(1)
      assert.equal(16, sim:input())
      assert.equal("laptop", sim:owner("laptop"))
    end)

    it("lets the node that started first sleep-broadcast to the late peer", function()
      local sim = reverseStart()
      sim:activate("laptop")
      sim:advance(1)
      sim:sleep("laptop")
      assert.equal(1, #sim:sent({ from = "laptop", to = "desk-mini", sync = true }))
      assert.equal("desk-mini", sim:owner("desk-mini"))
      assert.is_false(sim:presence("desk-mini", "laptop").active)
    end)

    it("re-sends hello on the heartbeat until the alias is learned", function()
      local sim = reverseStart()
      sim.entries.laptop.aliases = {} -- as if the first hello round trip had been lost
      local before = #sim:sent({ from = "laptop", type = "hello" })
      sim:advance(30)
      assert.equal(before + 1, #sim:sent({ from = "laptop", type = "hello" }))
      assert.equal(STATIC["desk-mini"], sim.entries.laptop.aliases["desk-mini"])
      local states = #sim:sent({ from = "laptop", type = "state" })
      sim:advance(30)
      assert.equal(before + 1, #sim:sent({ from = "laptop", type = "hello" }))
      assert.is_true(#sim:sent({ from = "laptop", type = "state" }) > states)
    end)
  end)
end)

describe("Node start", function()
  it("fails without starting anything when the transport cannot listen", function()
    local sim = make({ delayed = true })
    local entry = sim.entries.laptop
    entry.transport.start = function() return false, "cannot listen on port 8765" end
    local ok, why = entry.node:start()
    assert.is_false(ok)
    assert.equal("cannot listen on port 8765", why)
    assert.is_nil(entry.discoveryStarted)
    assert.is_nil(entry.onActivity)
    assert.is_false(entry.node.running)
  end)
end)

describe("Node protocol", function()
  local function request(sim, body)
    return sim:node("desk-mini"):onMessage({ type = "request", from = "laptop", instance = "x", ts = 0, body = body })
  end

  it("answers a valid request with ok after switching and recording the requester", function()
    local sim = make()
    local status, reply = request(sim, { display = "left", to = "laptop" })
    assert.equal(200, status)
    assert.same({ result = "ok" }, reply)
    assert.equal(16, sim:input())
    assert.equal("laptop", sim:owner("desk-mini"))
  end)

  it("maps the display reason unknown-node to the wire reason unknown-display", function()
    local sim = make()
    local status, reply = request(sim, { display = "left", to = "ghost" })
    assert.equal(200, status)
    assert.same({ result = "failed", reason = "unknown-display" }, reply)
    assert.equal(15, sim:input())
  end)

  it("answers not-visible and backend-error as such", function()
    local sim = make({ input = 16 })
    local _, reply = request(sim, { display = "left", to = "laptop" })
    assert.same({ result = "failed", reason = "not-visible" }, reply)

    local sim2 = make()
    sim2.monitor.failing = true
    _, reply = request(sim2, { display = "left", to = "laptop" })
    assert.same({ result = "failed", reason = "backend-error" }, reply)
    assert.equal(15, sim2:input())
    assert.is_nil(sim2:owner("desk-mini"))
  end)

  it("answers a malformed or unknown-display request as failed unknown-display", function()
    local sim = make()
    for _, body in ipairs({ {}, { display = "left" }, { to = "laptop" }, { display = "nope", to = "laptop" } }) do
      local status, reply = request(sim, body)
      assert.equal(200, status)
      assert.same({ result = "failed", reason = "unknown-display" }, reply)
    end
  end)

  it("replies to hello with the full state and to state with 204", function()
    local sim = make()
    local node = sim:node("desk-mini")
    local status, reply = node:onMessage({ type = "hello", from = "laptop", instance = "x", ts = 0, body = {} })
    assert.equal(200, status)
    assert.is_table(reply.state)
    status, reply = node:onMessage({ type = "state", from = "laptop", instance = "x", ts = 0, body = "junk" })
    assert.equal(204, status)
    assert.is_nil(reply)
  end)

  it("merges the state carried by hello and state messages", function()
    local sim = make()
    local node = sim:node("desk-mini")
    local owner = { left = { node = "laptop", ts = sim.now() + 5 } }
    node:onMessage({ type = "state", from = "laptop", instance = "x", ts = 0, body = { state = { owner = owner } } })
    assert.equal("laptop", sim:owner("desk-mini"))
  end)

  it("answers an unknown message type with 404 and no body", function()
    local sim = make()
    local msg = { type = "bogus", from = "laptop", instance = "x", ts = 0, body = {} }
    local status, reply = sim:node("desk-mini"):onMessage(msg)
    assert.equal(404, status)
    assert.is_nil(reply)
  end)

  it("sends state heartbeats every heartbeat interval", function()
    local sim = make()
    local before = #sim:sent({ from = "laptop", type = "state" })
    sim:advance(30)
    assert.is_true(#sim:sent({ from = "laptop", type = "state" }) > before)
  end)
end)

describe("Node manual control and lifecycle", function()
  it("claim() makes an idle node active and claims the display", function()
    local sim = make()
    assert.is_true(sim:node("laptop"):claim())
    sim:advance(1)
    assert.equal(16, sim:input())
    assert.is_true(sim:presence("desk-mini", "laptop").active)
    allOwners(sim, { "desk-mini", "laptop" }, "laptop")
  end)

  it("claim(id) forces the attempt even when the recorded owner is already me", function()
    local sim = make({ mode = "sticky", acceptsInactive = true })
    sim:activate("laptop")
    sim:advance(1)
    local before = sim.counts.laptop.switchTo
    assert.is_true(sim:node("laptop"):claim("left"))
    sim:advance(1)
    assert.equal(before + 1, sim.counts.laptop.switchTo)
  end)

  it("claim() of an unknown display returns false", function()
    local sim = make()
    assert.is_false(sim:node("laptop"):claim("nope"))
  end)

  it("release() hands the display back like a lock without the sleep path", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    sim:node("laptop"):release()
    sim:advance(1)
    assert.equal(15, sim:input())
    assert.is_false(sim:presence("desk-mini", "laptop").active)
  end)

  it("a closed lid releases the display and an opened, unlocked lid claims it again", function()
    local sim = make({ lid = true })
    sim:activate("laptop")
    sim:advance(1)
    sim:lid("laptop", true)
    sim:advance(1)
    assert.equal(15, sim:input())
    sim:lid("laptop", false)
    sim:advance(1)
    assert.equal(16, sim:input())
  end)

  it("an opened lid while the session is locked does not claim", function()
    local sim = make({ lid = true })
    sim:lid("laptop", true)
    sim:lid("laptop", false)
    sim:advance(1)
    assert.equal(15, sim:input())
  end)

  it("stop() cancels the heartbeat and pending claim retries", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    sim:partition("laptop", true)
    sim:activate("desk-mini")
    sim:advance(3) -- a retry is waiting
    sim:node("desk-mini"):stop()
    sim:node("laptop"):stop()
    sim:advance(1)
    assert.equal(0, sim.timer.pending())
  end)
end)
