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
    monitor = {
      inputs = inputs, mode = o.mode, acceptsInactive = o.acceptsInactive, input = o.input,
      control = o.control, noDdc = o.noDdc,
    },
  })
  if not o.delayed then
    sim:start()
    sim:advance(1)
  end
  return sim
end

local function requests(sim, from) return #sim:sent({ from = from, type = "request" }) end

-- Log messages of `node` at `level` that contain `text` (plain match).
local function logged(sim, node, level, text)
  local out = {}
  for _, line in ipairs(sim.logLines) do
    local who, lvl, msg = line:match("^(%S+) (%a) (.*)$")
    if who == node and lvl == level and msg:find(text, 1, true) then out[#out + 1] = msg end
  end
  return out
end

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
    -- The laptop stays alive but cannot switch. (A partitioned laptop would be silent for more than 90 s by
    -- the third round, and a claim with the display absent and nobody alive ends quietly since 0.2.2.)
    sim.monitor.failing = true
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

  describe("consecutive inactivity events", function()
    local function logs(sim, node, level)
      local out = {}
      for _, line in ipairs(sim.logLines) do
        local who, lvl, msg = line:match("^(%S+) (%a) (.*)$")
        if who == node and lvl == level then out[#out + 1] = msg end
      end
      return out
    end

    local function matching(lines, pattern)
      local n = 0
      for _, line in ipairs(lines) do
        if line:find(pattern, 1, true) then n = n + 1 end
      end
      return n
    end

    local function activeLaptop(o)
      local sim = make(o)
      sim:activate("laptop")
      sim:advance(1)
      assert.equal(16, sim:input())
      return sim, sim.counts.laptop.switchTo, sim.monitor.applied
    end

    it("A1 a lock followed at once by a sleep starts one async release and logs no error", function()
      local sim, switches = activeLaptop()
      sim:lock("laptop")
      sim:sleep("laptop") -- the async release is still in flight
      sim:advance(5)
      assert.equal(switches + 1, sim.counts.laptop.switchTo)
      assert.equal(15, sim:input())
      assert.same({}, logs(sim, "laptop", "e"))
      allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
    end)

    it("A2 a lid close followed by a lock starts one async release and logs no error", function()
      local sim, switches = activeLaptop({ lid = true })
      sim:lid("laptop", true)
      sim:lock("laptop")
      sim:advance(5)
      assert.equal(switches + 1, sim.counts.laptop.switchTo)
      assert.equal(15, sim:input())
      assert.same({}, logs(sim, "laptop", "e"))
      assert.equal(1, matching(logs(sim, "laptop", "d"), "in flight"))
      allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
    end)

    it("A3 a sleep after the async release has landed does nothing more", function()
      local sim, _, applied = activeLaptop()
      sim:lock("laptop")
      sim:advance(1)
      assert.equal(15, sim:input())
      sim:sleep("laptop")
      sim:advance(5)
      assert.equal(applied + 1, sim.monitor.applied)
      assert.equal(15, sim:input())
      assert.same({}, logs(sim, "laptop", "e"))
      allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
    end)

    it("A4 a second async inactivity event after the release landed does nothing more", function()
      local sim, _, applied = activeLaptop()
      sim:lock("laptop")
      sim:advance(1)
      sim:lock("laptop")
      sim:advance(5)
      assert.equal(applied + 1, sim.monitor.applied)
      assert.same({}, logs(sim, "laptop", "e"))
    end)

    it("A5 a release that finds the display not visible logs info and keeps the owner", function()
      local sim = activeLaptop()
      sim.monitor.input = 15 -- the monitor was switched away behind the laptop's back
      sim:lock("laptop")
      sim:advance(5)
      assert.same({}, logs(sim, "laptop", "e"))
      assert.equal(1, matching(logs(sim, "laptop", "i"), "already handed over"))
      assert.equal("laptop", sim:owner("laptop"))
    end)

    it("A6 a sync release that finds the display not visible logs info and keeps the owner", function()
      local sim = activeLaptop()
      sim.monitor.input = 15
      sim:sleep("laptop")
      assert.same({}, logs(sim, "laptop", "e"))
      assert.equal(1, matching(logs(sim, "laptop", "i"), "already handed over"))
      assert.equal("laptop", sim:owner("laptop"))
    end)

    it("A7 a backend error on a display that is still visible stays an error", function()
      local sim = activeLaptop()
      sim.monitor.failing = true
      sim:lock("laptop")
      sim:advance(5)
      assert.equal(1, matching(logs(sim, "laptop", "e"), "release of left failed: backend-error"))
      assert.equal(0, matching(logs(sim, "laptop", "i"), "already handed over"))
    end)

    it("A8 a sync backend error stays an error", function()
      local sim = activeLaptop()
      sim.monitor.failing = true
      sim:sleep("laptop")
      assert.equal(1, matching(logs(sim, "laptop", "e"), "release of left failed: backend-error"))
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

  describe("lid state at start", function()
    local function startActive(o, closed)
      local sim = make({ lid = o.lid, delayed = true })
      sim:setLocked("laptop", false)
      sim:setIdle("laptop", 0)
      sim:setClosed("laptop", closed)
      sim:start()
      return sim
    end

    local function infoLines(sim, pattern)
      local n = 0
      for _, line in ipairs(sim.logLines) do
        if line:find("^laptop i ") and line:find(pattern, 1, true) then n = n + 1 end
      end
      return n
    end

    it("L1 a lid found closed while the node started active releases like a lid close", function()
      local sim = startActive({ lid = true }, true)
      sim:advance(10)
      assert.equal(1, infoLines(sim, "inactive (lid closed (start))"))
      assert.equal(15, sim:input())
      assert.is_false(sim:presence("desk-mini", "laptop").active)
      assert.is_false(sim:presence("laptop", "laptop").active)
      assert.is_true(sim:node("laptop").lidClosed)
      sim:setLocked("laptop", false)
      sim:activate("laptop") -- ignored while the lid is closed
      sim:advance(5)
      assert.equal(15, sim:input())
    end)

    it("L2 an open lid at start changes nothing", function()
      local sim = startActive({ lid = true }, false)
      sim:advance(10)
      assert.equal(0, infoLines(sim, "lid closed"))
      assert.equal(16, sim:input())
      assert.is_true(sim:presence("desk-mini", "laptop").active)
    end)

    it("L3 a closed lid is ignored when the lid sensor is not enabled", function()
      local sim = startActive({ lid = false }, true)
      sim:advance(10)
      assert.equal(0, infoLines(sim, "lid closed"))
      assert.equal(16, sim:input())
    end)

    it("L4 a lid found closed on an inactive node does not release but blocks activity until it opens", function()
      local sim = make({ lid = true, delayed = true })
      sim:setClosed("laptop", true)
      sim:start()
      sim:advance(1)
      assert.equal(0, infoLines(sim, "inactive (lid closed (start))"))
      assert.is_true(sim:node("laptop").lidClosed)
      sim:activate("laptop")
      sim:advance(5)
      assert.equal(15, sim:input())
      sim:lid("laptop", false)
      sim:advance(5)
      assert.equal(16, sim:input())
    end)

    it("L5 a stop before the first read completes ignores the late result", function()
      local sim = startActive({ lid = true }, true)
      sim:node("laptop"):stop()
      sim:advance(1)
      assert.equal(0, infoLines(sim, "lid closed (start)"))
    end)
  end)

  it("an opened lid while the session is locked does not claim", function()
    local sim = make({ lid = true })
    sim:lid("laptop", true)
    sim:lid("laptop", false)
    sim:advance(1)
    assert.equal(15, sim:input())
  end)

  it("stop() cancels the in-flight switches of every display", function()
    local sim = make()
    sim:node("laptop"):stop()
    assert.equal(1, sim.counts.laptop.cancel)
    assert.equal(0, sim.counts["desk-mini"].cancel)
    sim:node("laptop"):stop() -- a second stop does nothing
    assert.equal(1, sim.counts.laptop.cancel)
  end)

  it("a release cancelled by stop() leaves no release marked in flight", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    sim:lock("laptop")
    sim:node("laptop"):stop()
    assert.same({}, sim:node("laptop").releasing)
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

-- The desk-mini has no working DDC (fact F1): only the laptop is in `control`. The monitor is sticky
-- (always visible to both) and, like the real one driven over USB-C, accepts commands whatever it shows.
describe("control (nodes without DDC)", function()
  local function makeControl()
    local sim = Sim.new({
      nodes = { "desk-mini", "laptop" },
      home = "desk-mini",
      monitor = {
        inputs = { ["desk-mini"] = 17, laptop = 21 }, mode = "sticky", acceptsInactive = true,
        control = { "laptop" }, noDdc = { "desk-mini" },
      },
    })
    sim:start()
    sim:advance(1)
    return sim
  end

  -- Both nodes are known to each other; the laptop is active and owns the monitor.
  local function laptopOwns()
    local sim = makeControl()
    sim:activate("laptop")
    sim:advance(1)
    assert.equal(21, sim:input())
    return sim
  end

  it("C1 laptop unlock: laptop pulls itself", function()
    local sim = makeControl()
    sim:activate("laptop")
    sim:advance(1)
    assert.equal(21, sim:input())
    allOwners(sim, { "desk-mini", "laptop" }, "laptop")
    assert.equal(0, sim:ddcCalls("desk-mini"))
  end)

  it("C2 laptop lock: laptop pushes to desk-mini", function()
    local sim = laptopOwns()
    sim:lock("laptop")
    sim:advance(1)
    assert.equal(17, sim:input())
    allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
    assert.equal(0, sim:ddcCalls("desk-mini"))
  end)

  it("C3 desk-mini active while laptop owns: desk-mini asks laptop", function()
    local sim = laptopOwns()
    sim:activate("desk-mini")
    sim:advance(1)
    assert.equal(17, sim:input())
    allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
    assert.is_true(#sim:sent({ from = "desk-mini", type = "request" }) > 0)
    assert.equal(0, sim:ddcCalls("desk-mini"))
  end)

  it("C4 desk-mini release while it owns and laptop is active: delegates to laptop", function()
    local sim = laptopOwns()
    sim:activate("desk-mini")
    sim:advance(1)
    assert.equal(17, sim:input())
    sim:lock("desk-mini")
    sim:advance(1)
    assert.equal(21, sim:input())
    allOwners(sim, { "desk-mini", "laptop" }, "laptop")
    assert.equal(0, sim:ddcCalls("desk-mini"))
    local requests_ = sim:sent({ from = "desk-mini", type = "request" })
    assert.equal("laptop", requests_[#requests_].to)
    assert.same({ display = "left", to = "laptop" }, requests_[#requests_].body)
  end)

  it("C4b a delegated release reaches a target other than the controller", function()
    local sim = Sim.new({
      nodes = { "desk-mini", "laptop", "studio" }, home = "desk-mini",
      monitor = {
        inputs = ALL_INPUTS, mode = "sticky", acceptsInactive = true, input = 15,
        control = { "laptop" }, noDdc = { "desk-mini", "studio" },
      },
    })
    sim:start()
    sim:advance(1)
    sim:activate("laptop")
    sim:advance(1)
    sim:activate("desk-mini")
    sim:advance(1)
    sim:activate("studio") -- studio is now the latest active peer
    sim:advance(1)
    assert.equal(17, sim:input())
    sim:lock("studio")
    sim:advance(1)
    -- studio's release was delegated to the laptop and went to the latest active peer
    assert.equal(15, sim:input())
    allOwners(sim, { "desk-mini", "laptop", "studio" }, "desk-mini")
    sim:lock("desk-mini")
    sim:advance(1)
    -- desk-mini holds no DDC and the best peer is laptop (still active)
    assert.equal(16, sim:input())
    assert.equal(0, sim:ddcCalls("desk-mini"))
    assert.equal(0, sim:ddcCalls("studio"))
  end)

  it("C5 desk-mini refuses a request (not-capable) and sends no DDC", function()
    local sim = makeControl()
    local status, reply = sim:node("desk-mini"):onMessage({
      type = "request", from = "laptop", instance = "x", ts = 0, body = { display = "left", to = "laptop" },
    })
    assert.equal(200, status)
    assert.same({ result = "failed", reason = "not-capable" }, reply)
    assert.equal(0, sim:ddcCalls("desk-mini"))
    assert.equal(17, sim:input())
  end)

  it("C6 laptop offline: desk-mini claim exhausts and notifies once", function()
    local sim = laptopOwns()
    sim:partition("laptop", true)
    sim:activate("desk-mini")
    sim:advance(30)
    assert.equal(1, sim:notified("claim-failed", "desk-mini"))
    assert.equal(0, sim:ddcCalls("desk-mini"))
    assert.equal(21, sim:input())
  end)

  it("C6a laptop locked then away for 200 s: desk-mini activates without a claim error", function()
    local sim = laptopOwns()
    sim:lock("laptop")
    sim:advance(1)
    assert.equal("desk-mini", sim:owner("desk-mini"))
    sim:partition("laptop", true)
    sim:advance(200)
    sim:activate("desk-mini")
    sim:advance(30)
    assert.equal(0, sim:notified("claim-failed"))
    assert.equal("desk-mini", sim:owner("desk-mini"))
    assert.same({}, logged(sim, "desk-mini", "e", "cannot claim"))
    assert.equal(1, #logged(sim, "desk-mini", "i", "no controller reachable for left"))
    assert.same({}, sim:node("desk-mini").intents)
    assert.equal(0, sim:ddcCalls("desk-mini"))
  end)

  it("C6b owner unknown and desk-mini is home: no controller reachable assumes the display is here", function()
    local sim = makeControl()
    sim:partition("laptop", true)
    sim:advance(200)
    assert.is_nil(sim:owner("desk-mini"))
    sim:activate("desk-mini")
    sim:advance(30)
    assert.equal(0, sim:notified("claim-failed"))
    assert.equal("desk-mini", sim:owner("desk-mini"))
    assert.same({}, logged(sim, "desk-mini", "e", "cannot claim"))
    assert.same({}, sim:node("desk-mini").intents)
  end)

  it("C6c an asleep laptop still counted alive: the claim times out without an error when desk-mini owns", function()
    local sim = laptopOwns()
    sim:lock("laptop")
    sim:advance(1)
    sim:partition("laptop", true)
    sim:advance(10) -- the laptop is still alive for desk-mini, requests time out
    sim:activate("desk-mini")
    sim:advance(30)
    assert.equal(0, sim:notified("claim-failed"))
    assert.equal("desk-mini", sim:owner("desk-mini"))
    assert.same({}, logged(sim, "desk-mini", "e", "cannot claim"))
  end)

  it("C7 claim() on desk-mini while the laptop owns behaves like C3", function()
    local sim = laptopOwns()
    assert.is_true(sim:node("desk-mini"):claim())
    sim:advance(1)
    assert.equal(17, sim:input())
    allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
    assert.is_true(#sim:sent({ from = "desk-mini", type = "request" }) > 0)
    assert.equal(0, sim:ddcCalls("desk-mini"))
  end)

  it("a node inside control never sends a request for itself, even when desk-mini owns the record", function()
    local sim = makeControl()
    sim:activate("desk-mini") -- owner unknown: asks the laptop
    sim:advance(1)
    assert.equal("desk-mini", sim:owner("laptop"))
    sim:activate("laptop") -- pulls itself instead of asking desk-mini, which could not switch anyway
    sim:advance(1)
    assert.equal(0, #sim:sent({ from = "laptop", type = "request" }))
    assert.equal(21, sim:input())
  end)

  it("a delegated release is in flight once per display", function()
    local sim = laptopOwns()
    sim:activate("desk-mini")
    sim:advance(1)
    local before = #sim:sent({ from = "desk-mini", type = "request" })
    sim:lock("desk-mini")
    sim:lock("desk-mini") -- second inactivity event before the first request has been answered
    assert.equal(before + 1, #sim:sent({ from = "desk-mini", type = "request" }))
    sim:advance(1)
    assert.same({}, sim:node("desk-mini").releasing)
    assert.equal(21, sim:input())
  end)

  it("a delegated release that the controller refuses leaves the owner alone and logs a warning", function()
    local sim = laptopOwns()
    sim:activate("desk-mini")
    sim:advance(1)
    sim.monitor.failing = true
    sim:lock("desk-mini")
    sim:advance(1)
    assert.equal(17, sim:input())
    assert.equal("desk-mini", sim:owner("desk-mini"))
    assert.same({}, sim:node("desk-mini").releasing)
    local warnings = logged(sim, "desk-mini", "w", "cannot hand over left")
    assert.equal(1, #warnings)
    assert.truthy(warnings[1]:find("laptop", 1, true))
    assert.truthy(warnings[1]:find("backend-error", 1, true))
    assert.same({}, logged(sim, "desk-mini", "i", "already handed over"))
    assert.same({}, logged(sim, "desk-mini", "e", "release of left failed"))
  end)

  it("a delegated release with no capable peer alive warns once per inactivity event", function()
    local sim = laptopOwns()
    sim:activate("desk-mini")
    sim:advance(1)
    sim:partition("laptop", true)
    sim:lock("desk-mini")
    sim:lock("desk-mini") -- the same event again while the first release is still in flight
    sim:advance(1)
    local warnings = logged(sim, "desk-mini", "w", "cannot hand over left")
    assert.equal(1, #warnings)
    assert.same({}, logged(sim, "desk-mini", "i", "already handed over"))
    assert.same({}, logged(sim, "desk-mini", "e", "release of left failed"))
    assert.equal("desk-mini", sim:owner("desk-mini"))
  end)

  it("a delegated release with every controller gone for good warns about it in its own words", function()
    local sim = Sim.new({
      nodes = { "desk-mini", "laptop", "studio" }, home = "desk-mini",
      monitor = {
        inputs = ALL_INPUTS, mode = "sticky", acceptsInactive = true, input = 15,
        control = { "laptop" }, noDdc = { "desk-mini", "studio" },
      },
    })
    sim:start()
    sim:advance(1)
    sim:activate("laptop")
    sim:advance(1)
    sim:activate("studio")
    sim:advance(1)
    sim:activate("desk-mini")
    sim:advance(1)
    assert.equal("desk-mini", sim:owner("desk-mini"))
    sim:partition("laptop", true)
    sim:advance(100) -- the laptop is no longer alive, studio still is
    sim:lock("desk-mini")
    sim:advance(1)
    local warnings = logged(sim, "desk-mini", "w", "cannot hand over left")
    assert.equal(1, #warnings)
    assert.truthy(warnings[1]:find("no node with control", 1, true))
    assert.same({}, logged(sim, "desk-mini", "i", "already handed over"))
  end)

  it("a successful delegated release logs no misleading 'landed but' line", function()
    local sim = laptopOwns()
    sim:activate("desk-mini")
    sim:advance(1)
    sim:lock("desk-mini")
    sim:advance(2)
    assert.equal(21, sim:input())
    assert.equal("laptop", sim:owner("desk-mini"))
    assert.same({}, logged(sim, "desk-mini", "i", "landed but"))
    assert.same({}, logged(sim, "desk-mini", "w", "cannot hand over"))
  end)

  it("a delegated release landing after desk-mini became active again claims afresh", function()
    local sim = laptopOwns()
    sim:activate("desk-mini")
    sim:advance(1)
    sim:lock("desk-mini")
    sim:activate("desk-mini") -- before the controller answered
    sim:advance(2)
    assert.equal(17, sim:input())
    assert.equal("desk-mini", sim:owner("desk-mini"))
    assert.equal(0, sim:ddcCalls("desk-mini"))
  end)

  it("a delegated release landing after someone else took the display writes and broadcasts nothing", function()
    local sim = laptopOwns()
    sim:activate("desk-mini")
    sim:advance(1)
    sim:lock("desk-mini")
    -- before the answer arrives the state says someone else owns it
    sim:state("desk-mini"):setOwner("left", "laptop", sim.now() + 10)
    local before = #sim:sent({ from = "desk-mini", type = "state" })
    sim:advance(1)
    assert.equal("laptop", sim:owner("desk-mini"))
    assert.equal(before, #sim:sent({ from = "desk-mini", type = "state" }))
  end)

  it("sleep on desk-mini delegates its release (best effort, asynchronous)", function()
    local sim = laptopOwns()
    sim:activate("desk-mini")
    sim:advance(1)
    sim:sleep("desk-mini")
    assert.equal(0, sim.counts["desk-mini"].switchToSync)
    sim:advance(1)
    assert.equal(21, sim:input())
    assert.equal(0, sim:ddcCalls("desk-mini"))
  end)

  it("status() reports the control list", function()
    local sim = makeControl()
    assert.same({ "laptop" }, sim:node("desk-mini"):status().displays.left.control)
  end)

  it("without control every node switches itself (0.1.x behaviour)", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    assert.same({ "desk-mini", "laptop" }, sim:node("laptop"):status().displays.left.control)
    assert.equal(0, sim:ddcCalls("desk-mini"))
  end)

  it("status() falls back to the sorted input nodes exactly like _canSwitch when control is missing", function()
    local sim = make({ nodes = { "laptop", "studio", "desk-mini" } })
    local node = sim:node("laptop")
    node.cfg.displays.left.control = nil
    local reported = node:status().displays.left.control
    assert.same({ "desk-mini", "laptop", "studio" }, reported)
    for _, name in ipairs({ "desk-mini", "laptop", "studio" }) do
      assert.is_true(node:_canSwitch("left", name))
    end
  end)
end)

-- R2: a node without the display mirrors it onto another of its screens while another node owns it.
-- Same setup as "control": desk-mini has no DDC, the laptop controls the monitor.
describe("whenAway mirror", function()
  local function makeMirror(o)
    o = o or {}
    local sim = Sim.new({
      nodes = { "desk-mini", "laptop" },
      home = "desk-mini",
      whenAway = o.whenAway == nil and { ["desk-mini"] = "mirror" } or o.whenAway or nil,
      mirrorTo = o.mirrorTo,
      monitor = {
        inputs = { ["desk-mini"] = 17, laptop = 21 }, mode = "sticky", acceptsInactive = true,
        control = { "laptop" }, noDdc = { "desk-mini" },
      },
    })
    sim:start()
    sim:advance(1)
    return sim
  end

  local function laptopOwns(o)
    local sim = makeMirror(o)
    sim:activate("laptop")
    sim:advance(1)
    return sim
  end

  it("M1 laptop takes the display: desk-mini mirrors", function()
    local sim = laptopOwns()
    assert.equal(21, sim:input())
    assert.is_true(sim:mirrored("desk-mini"))
    assert.is_false(sim:mirrored("laptop"))
    assert.is_true(sim:node("desk-mini"):status().displays.left.mirrored)
    assert.is_false(sim:node("laptop"):status().displays.left.mirrored)
    assert.equal(1, #logged(sim, "desk-mini", "i", "mirroring left (owned by laptop)"))
  end)

  it("M2 laptop locks: desk-mini stops mirroring", function()
    local sim = laptopOwns()
    sim:lock("laptop")
    sim:advance(1)
    assert.equal(17, sim:input())
    assert.is_false(sim:mirrored("desk-mini"))
    assert.equal(1, #logged(sim, "desk-mini", "i", "left is back, mirror stopped"))
  end)

  it("M3 desk-mini claims via request: mirror stops at once and no retry follows", function()
    local sim = laptopOwns()
    sim:activate("desk-mini")
    sim:advance(10)
    assert.equal(17, sim:input())
    assert.is_false(sim:mirrored("desk-mini"))
    assert.equal(1, requests(sim, "desk-mini"))
    assert.equal(0, sim:notified("claim-failed"))
  end)

  it("M3b a display that stays out of sight does not make the verification retry the claim", function()
    local sim = laptopOwns()
    -- the monitor 'disappears' from allScreens() while the screen is mirrored
    sim:node("desk-mini").displays.left.visible = function() return false end
    sim:activate("desk-mini")
    sim:advance(10)
    assert.equal("desk-mini", sim:owner("desk-mini"))
    assert.equal(1, requests(sim, "desk-mini"))
    assert.equal(0, sim:notified("claim-failed"))
    assert.same({}, sim:node("desk-mini").intents)
    assert.same({}, logged(sim, "desk-mini", "w", "not visible"))
  end)

  it("M4 heartbeats and hellos with an unchanged owner do not toggle the mirror", function()
    local sim = laptopOwns()
    sim:hello("laptop")
    sim:hello("desk-mini")
    sim:advance(120)
    assert.equal(1, sim:mirrorCalls("desk-mini").mirror)
    assert.equal(0, sim:mirrorCalls("desk-mini").unmirror)
    assert.is_true(sim:mirrored("desk-mini"))
  end)

  it("M5 stop() stops the mirror", function()
    local sim = laptopOwns()
    assert.is_true(sim:mirrored("desk-mini"))
    sim:node("desk-mini"):stop()
    assert.is_false(sim:mirrored("desk-mini"))
  end)

  it("M5b stop() without a mirror asks for nothing", function()
    local sim = makeMirror()
    sim:node("desk-mini"):stop()
    assert.equal(0, sim:mirrorCalls("desk-mini").unmirror)
  end)

  it("M6 restart learns the owner from hello and mirrors", function()
    local sim = laptopOwns()
    sim:restart("desk-mini")
    sim:advance(1)
    assert.is_true(sim:mirrored("desk-mini"))
  end)

  it("M7 no whenAway: never mirrors", function()
    local sim = laptopOwns({ whenAway = false })
    assert.equal(21, sim:input())
    assert.equal(0, sim:mirrorCalls("desk-mini").mirror)
    assert.is_false(sim:mirrored("desk-mini"))
  end)

  it("M8 mirrorTo is handed to the adapter and remembered for the unmirror", function()
    local sim = laptopOwns({ mirrorTo = { ["desk-mini"] = "UUID-secondary" } })
    assert.equal("UUID-secondary", sim:node("desk-mini").mirrored.left)
    sim:lock("laptop")
    sim:advance(1)
    assert.is_nil(sim:node("desk-mini").mirrored.left)
  end)

  it("M9 a failed mirror is retried on the next state, warned about once per owner", function()
    local sim = makeMirror()
    sim.mirrorFails["desk-mini"] = true
    sim:activate("laptop")
    sim:advance(1)
    sim:advance(95) -- several heartbeats with the same owner
    assert.is_false(sim:mirrored("desk-mini"))
    assert.is_true(sim:mirrorCalls("desk-mini").mirror > 1)
    assert.equal(1, #logged(sim, "desk-mini", "w", "cannot mirror left"))
    sim.mirrorFails["desk-mini"] = false
    sim:advance(31)
    assert.is_true(sim:mirrored("desk-mini"))
  end)

  it("M10 the display is not visible to the node yet: no mirror, no error", function()
    local sim = makeMirror()
    sim:node("desk-mini").displays.left.target = function() return nil end
    sim:activate("laptop")
    sim:advance(1)
    assert.equal(0, sim:mirrorCalls("desk-mini").mirror)
    assert.is_false(sim:mirrored("desk-mini"))
  end)

  -- A mirror survives a Hammerspoon reload without stop() or a crash: the source screen is then missing
  -- from the screens at start. desk-mini is built but not started; the stale mirror is simulated.
  local function staleMirror(owner)
    local sim = Sim.new({
      nodes = { "desk-mini", "laptop" },
      home = "desk-mini",
      whenAway = { ["desk-mini"] = "mirror" },
      monitor = {
        inputs = { ["desk-mini"] = 17, laptop = 21 }, mode = "sticky", acceptsInactive = true,
        control = { "laptop" }, noDdc = { "desk-mini" },
      },
    })
    sim:start("laptop")
    sim:advance(1)
    sim.mirroring["desk-mini"] = true
    if owner then sim:state("desk-mini"):setOwner("left", owner, sim.now()) end
    return sim
  end

  it("M12 a stale mirror at start with the owner already known to be this node is stopped", function()
    local sim = staleMirror("desk-mini")
    sim:start("desk-mini")
    assert.is_false(sim:mirrored("desk-mini"))
    assert.equal(1, sim:mirrorCalls("desk-mini").unmirror)
    assert.equal(0, sim:mirrorCalls("desk-mini").mirror)
    assert.is_false(sim:node("desk-mini"):status().displays.left.mirrored)
  end)

  it("M13 a stale mirror at start with an unknown owner waits for the first peer state, then is stopped", function()
    local sim = staleMirror()
    sim:start("desk-mini")
    assert.is_true(sim:mirrored("desk-mini")) -- grace period: nothing is known yet
    assert.equal(0, sim:mirrorCalls("desk-mini").unmirror)
    sim:advance(1) -- the laptop's state arrives and names no owner
    assert.is_false(sim:mirrored("desk-mini"))
    assert.equal(1, sim:mirrorCalls("desk-mini").unmirror)
    assert.equal(0, sim:mirrorCalls("desk-mini").mirror)
  end)

  it("M13b reload while the laptop owns the display: the mirror is neither dropped nor repeated", function()
    local sim = staleMirror()
    sim:activate("laptop")
    sim:advance(1)
    sim:start("desk-mini") -- reload without stop(): the state is empty, the mirror is still there
    sim:advance(10)
    assert.equal("laptop", sim:owner("desk-mini"))
    assert.is_true(sim:mirrored("desk-mini"))
    assert.equal(0, sim:mirrorCalls("desk-mini").unmirror)
    assert.equal(0, sim:mirrorCalls("desk-mini").mirror)
    assert.is_true(sim:node("desk-mini"):status().displays.left.mirrored)
  end)

  it("M13c no peer answers within 5 s: the stale mirror is stopped then, not before", function()
    local sim = Sim.new({
      nodes = { "desk-mini", "laptop" },
      home = "desk-mini",
      whenAway = { ["desk-mini"] = "mirror" },
      monitor = {
        inputs = { ["desk-mini"] = 17, laptop = 21 }, mode = "sticky", acceptsInactive = true,
        control = { "laptop" }, noDdc = { "desk-mini" },
      },
    })
    sim.mirroring["desk-mini"] = true
    sim:start("desk-mini") -- the laptop is not running
    sim:advance(4.5)
    assert.is_true(sim:mirrored("desk-mini"))
    assert.equal(0, sim:mirrorCalls("desk-mini").unmirror)
    sim:advance(1)
    assert.is_false(sim:mirrored("desk-mini"))
    assert.equal(1, sim:mirrorCalls("desk-mini").unmirror)
  end)

  it("M13d the grace timer is gone after stop()", function()
    local sim = staleMirror()
    sim:start("desk-mini")
    sim:node("desk-mini"):stop()
    local before = sim:mirrorCalls("desk-mini").unmirror
    sim:advance(10)
    assert.equal(before, sim:mirrorCalls("desk-mini").unmirror)
  end)

  it("M18 a suspected mirror whose display turns out to be visible is dropped and mirrored for real", function()
    local sim = staleMirror("laptop") -- the display is absent at start; the laptop owns it
    sim:start("desk-mini")
    sim:advance(1)
    assert.is_true(sim:node("desk-mini"):status().displays.left.mirrored) -- suspected
    sim.mirroring["desk-mini"] = false -- the monitor is plugged in: it was never mirrored
    sim:advance(31) -- the next heartbeat state from the laptop
    assert.equal(0, sim:mirrorCalls("desk-mini").unmirror)
    assert.equal(1, sim:mirrorCalls("desk-mini").mirror)
    assert.is_true(sim:mirrored("desk-mini"))
  end)

  it("M18b a dropped suspected mirror is not reported as mirrored when mirroring then fails", function()
    local sim = staleMirror("laptop")
    sim:start("desk-mini")
    sim:advance(1)
    sim.mirroring["desk-mini"] = false
    sim.mirrorFails["desk-mini"] = true
    sim:advance(31)
    assert.equal(0, sim:mirrorCalls("desk-mini").unmirror)
    assert.is_false(sim:node("desk-mini"):status().displays.left.mirrored)
  end)

  it("M14 a stale mirror at start while another node owns the display stays, without a second mirror", function()
    local sim = staleMirror("laptop")
    sim:start("desk-mini")
    sim:advance(100)
    assert.is_true(sim:mirrored("desk-mini"))
    assert.equal(0, sim:mirrorCalls("desk-mini").unmirror)
    assert.equal(0, sim:mirrorCalls("desk-mini").mirror)
    assert.is_true(sim:node("desk-mini"):status().displays.left.mirrored)
    -- and it is stopped when the owner comes back
    sim:activate("laptop")
    sim:lock("laptop")
    sim:advance(1)
    assert.is_false(sim:mirrored("desk-mini"))
    assert.equal(1, sim:mirrorCalls("desk-mini").unmirror)
  end)

  it("M15 a stale mirror is stopped when this node becomes the owner later", function()
    local sim = staleMirror("laptop")
    sim:start("desk-mini")
    sim:advance(1)
    sim:activate("desk-mini")
    sim:advance(5)
    assert.equal("desk-mini", sim:owner("desk-mini"))
    assert.is_false(sim:mirrored("desk-mini"))
  end)

  it("M16 a display that is visible at start gets no recovery unmirror", function()
    local sim = makeMirror()
    assert.equal(0, sim:mirrorCalls("desk-mini").unmirror)
    assert.equal(0, sim:mirrorCalls("desk-mini").mirror)
  end)

  it("M17 a persistently failing unmirror warns once, not on every state change", function()
    local sim = laptopOwns()
    sim.unmirrorFails["desk-mini"] = true
    sim:lock("laptop")
    sim:advance(100) -- heartbeats with the same owner keep retrying
    assert.is_true(sim:mirrored("desk-mini"))
    assert.is_true(sim:mirrorCalls("desk-mini").unmirror > 1)
    assert.equal(1, #logged(sim, "desk-mini", "w", "cannot stop mirroring left"))
    sim.unmirrorFails["desk-mini"] = false
    sim:advance(31)
    assert.is_false(sim:mirrored("desk-mini"))
    -- the guard is reset by the success
    sim:activate("laptop")
    sim:advance(1)
    sim.unmirrorFails["desk-mini"] = true
    sim:lock("laptop")
    sim:advance(1)
    assert.equal(2, #logged(sim, "desk-mini", "w", "cannot stop mirroring left"))
  end)

  it("M4b a quick owner flip laptop -> desk-mini -> laptop costs one extra mirror/unmirror pair", function()
    local sim = laptopOwns()
    assert.equal(1, sim:mirrorCalls("desk-mini").mirror)
    sim:activate("desk-mini")
    sim:advance(0.5)
    sim:activate("laptop")
    sim:advance(0.5)
    assert.equal("laptop", sim:owner("desk-mini"))
    assert.equal(2, sim:mirrorCalls("desk-mini").mirror)
    assert.equal(1, sim:mirrorCalls("desk-mini").unmirror)
    assert.is_true(sim:mirrored("desk-mini"))
    sim:advance(120)
    assert.equal(2, sim:mirrorCalls("desk-mini").mirror)
    assert.equal(1, sim:mirrorCalls("desk-mini").unmirror)
  end)

  it("M11 after the mirror is stopped, further states do not stop it again", function()
    local sim = laptopOwns()
    sim:lock("laptop")
    sim:advance(1)
    sim:advance(60)
    assert.equal(1, sim:mirrorCalls("desk-mini").mirror)
    assert.equal(1, sim:mirrorCalls("desk-mini").unmirror)
  end)
end)

-- R3: without DDC on the home node the state must still recover when the monitor leaves a controller on its
-- own (F7: the monitor falls back to HDMI when the Thunderbolt cable is unplugged). Same setup as "control"
-- plus the mirror on desk-mini.
describe("state recovery without DDC", function()
  local function makeRecovery()
    local sim = Sim.new({
      nodes = { "desk-mini", "laptop" },
      home = "desk-mini",
      whenAway = { ["desk-mini"] = "mirror" },
      monitor = {
        inputs = { ["desk-mini"] = 17, laptop = 21 }, mode = "sticky", acceptsInactive = true,
        control = { "laptop" }, noDdc = { "desk-mini" },
      },
    })
    sim:start()
    sim:advance(1)
    return sim
  end

  -- C1: the laptop unlocked and owns the monitor; desk-mini mirrors it.
  local function laptopOwns()
    local sim = makeRecovery()
    sim:activate("laptop")
    sim:advance(1)
    assert.equal(21, sim:input())
    assert.is_true(sim:mirrored("desk-mini"))
    return sim
  end

  it("R3a unplugging the laptop hands the display to home in the state", function()
    local sim = laptopOwns()
    local before = sim:ddcCalls("laptop")
    sim:unplug("laptop")
    sim:advance(3)
    assert.equal(17, sim:input())
    allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
    assert.is_false(sim:mirrored("desk-mini"))
    assert.equal(before, sim:ddcCalls("laptop"))
    assert.equal(0, sim:ddcCalls("desk-mini"))
    assert.equal(1, #logged(sim, "laptop", "i", "left disappeared, assuming it switched to desk-mini"))
  end)

  it("R3a waits 2 s after the last screen change", function()
    local sim = laptopOwns()
    sim:unplug("laptop")
    sim:advance(1.5)
    assert.equal("laptop", sim:owner("laptop"))
    sim:entry("laptop").screenWatcher.fire() -- another change restarts the counter
    sim:advance(1.5)
    assert.equal("laptop", sim:owner("laptop"))
    sim:advance(1)
    assert.equal("desk-mini", sim:owner("laptop"))
  end)

  it("R3a backup via heartbeat", function()
    local sim = laptopOwns()
    sim:unplug("laptop", { silent = true })
    sim:advance(31)
    allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
    assert.is_false(sim:mirrored("desk-mini"))
  end)

  it("R3a does not fire while the display is visible", function()
    local sim = laptopOwns()
    sim:entry("laptop").screenWatcher.fire() -- an unrelated screen change
    sim:advance(120)
    allOwners(sim, { "desk-mini", "laptop" }, "laptop")
    assert.same({}, logged(sim, "laptop", "i", "disappeared"))
  end)

  it("R3a does not fire on a node outside control", function()
    local sim = makeRecovery()
    sim:activate("desk-mini")
    sim:advance(1)
    assert.equal("desk-mini", sim:owner("desk-mini"))
    sim:unplug("desk-mini", { silent = true })
    sim:advance(31)
    allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
    assert.same({}, logged(sim, "desk-mini", "i", "disappeared"))
  end)

  it("R3a does nothing for a controller that already handed the display over", function()
    local sim = laptopOwns()
    sim:lock("laptop")
    sim:advance(1)
    allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
    local sent = #sim:sent({ from = "laptop", type = "state" })
    sim:unplug("laptop")
    sim:advance(31)
    allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
    assert.same({}, logged(sim, "laptop", "i", "disappeared"))
    -- only the heartbeat state went out, no extra broadcast for a write
    assert.equal(sent + 1, #sim:sent({ from = "laptop", type = "state" }))
  end)

  it("R3a ignores a display this node is mirroring itself (hidden by its own doing)", function()
    local sim = Sim.new({
      nodes = { "desk-mini", "laptop" },
      home = "desk-mini",
      whenAway = { laptop = "mirror" },
      monitor = {
        inputs = { ["desk-mini"] = 17, laptop = 21 }, mode = "sticky", acceptsInactive = true,
        control = { "laptop" }, noDdc = { "desk-mini" },
      },
    })
    sim:start()
    sim:advance(1)
    sim:activate("desk-mini")
    sim:advance(1)
    assert.is_true(sim:mirrored("laptop"))
    assert.is_false(sim:node("laptop").displays.left:visible())
    -- the laptop is a controller and the state names it (as right after its own claim); the display is
    -- invisible only because of its mirror
    sim:state("laptop"):setOwner("left", "laptop", sim.now() + 10)
    sim:node("laptop"):_checkHeld()
    assert.equal("laptop", sim:owner("laptop"))
    assert.same({}, logged(sim, "laptop", "i", "disappeared"))
    -- without the mirror the same situation does count as a disappeared display
    sim:node("laptop").mirrored.left = nil
    sim:node("laptop"):_checkHeld()
    assert.equal("desk-mini", sim:owner("laptop"))
  end)

  it("R3a leaves a display alone while a claim intent is live, and acts once it is exhausted or gone", function()
    local sim = laptopOwns()
    local laptop = sim:node("laptop")
    sim:unplug("laptop", { silent = true })
    laptop.intents.left = { id = "left", attempts = 1 } -- a claim waiting for its verification
    laptop:_checkHeld()
    assert.equal("laptop", sim:owner("laptop"))
    laptop.intents.left.exhausted = true
    laptop:_checkHeld()
    assert.equal("desk-mini", sim:owner("laptop"))
  end)

  it("R3a is off when home can switch the display itself (0.1.x configs): claim verification keeps retrying", function()
    -- S7b setup (no `control`: every node switches itself), a monitor that never shows the claim, and a
    -- screen change at unlock: R3a must not write the home as owner behind the claim's back.
    local sim = make()
    sim.monitor.stuck = true
    sim:activate("laptop")
    sim:entry("laptop").screenWatcher.fire()
    sim:advance(60)
    assert.equal(5, requests(sim, "laptop"))
    assert.equal(1, sim:notified("claim-failed", "laptop"))
    assert.same({}, logged(sim, "laptop", "i", "disappeared"))
    assert.same({}, logged(sim, "laptop", "i", "lost to"))
  end)

  it("R3a is off for a heartbeat in a 0.1.x config too", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    sim:unplug("laptop", { silent = true })
    sim:advance(100)
    assert.equal("laptop", sim:owner("laptop"))
    assert.same({}, logged(sim, "laptop", "i", "disappeared"))
  end)

  it("R3a waits one debounce period after this node stopped mirroring the display", function()
    local sim = Sim.new({
      nodes = { "desk-mini", "laptop" },
      home = "desk-mini",
      whenAway = { laptop = "mirror" },
      monitor = {
        inputs = { ["desk-mini"] = 17, laptop = 21 }, mode = "sticky", acceptsInactive = true,
        control = { "laptop" }, noDdc = { "desk-mini" },
      },
    })
    sim:start()
    sim:advance(1)
    sim:activate("desk-mini")
    sim:advance(1)
    assert.is_true(sim:mirrored("laptop"))
    -- the laptop takes the display: its mirror stops, but the screen may take a moment to be listed again
    sim:node("laptop"):_writeOwner("left", "laptop")
    assert.is_false(sim:mirrored("laptop"))
    sim:unplug("laptop", { silent = true }) -- the display is still not listed
    sim:node("laptop"):_checkHeld()
    assert.equal("laptop", sim:owner("laptop"))
    sim:advance(1.9)
    assert.equal("laptop", sim:owner("laptop"))
    sim:advance(0.2) -- the suppressed check was rescheduled by itself
    assert.equal("desk-mini", sim:owner("laptop"))
  end)

  it("a heartbeat that writes through R3a carries the result: one state per peer, no extra broadcast", function()
    local sim = laptopOwns()
    sim:unplug("laptop", { silent = true })
    sim:advance(27) -- laptopOwns() ends at t = 2 s
    local before = #sim:sent({ from = "laptop", type = "state" })
    sim:advance(2) -- the heartbeat at t = 30
    assert.equal("desk-mini", sim:owner("laptop"))
    assert.equal(before + 1, #sim:sent({ from = "laptop", type = "state" }))
  end)

  it("a heartbeat that writes through R3b carries the result: one state per peer, no extra broadcast", function()
    local sim = laptopOwns()
    sim:partition("laptop", true)
    sim:advance(117) -- t = 119 s
    assert.equal("laptop", sim:owner("desk-mini"))
    local before = #sim:sent({ from = "desk-mini", type = "state" })
    sim:advance(2) -- the heartbeat at t = 120
    assert.equal("desk-mini", sim:owner("desk-mini"))
    assert.equal(before + 1, #sim:sent({ from = "desk-mini", type = "state" }))
  end)

  it("a screen-change check that writes still broadcasts at once", function()
    local sim = laptopOwns()
    local before = #sim:sent({ from = "laptop", type = "state" })
    sim:unplug("laptop")
    sim:advance(2.5)
    assert.equal("desk-mini", sim:owner("desk-mini"))
    assert.equal(before + 1, #sim:sent({ from = "laptop", type = "state" }))
  end)

  it("R3a leaves a display alone while its release is in flight", function()
    local sim = laptopOwns()
    sim:node("laptop").releasing.left = true
    sim:unplug("laptop", { silent = true })
    sim:node("laptop"):_checkHeld()
    assert.equal("laptop", sim:owner("laptop"))
  end)

  it("the screen watcher is created at start, and stopped with its pending check at stop()", function()
    local sim = laptopOwns()
    local watcher = sim:entry("laptop").screenWatcher.watchers[1]
    assert.is_true(watcher.started)
    sim:unplug("laptop")
    sim:node("laptop"):stop()
    assert.is_false(watcher.started)
    sim:advance(5)
    assert.equal("laptop", sim:owner("laptop"))
    assert.same({}, logged(sim, "laptop", "i", "disappeared"))
  end)

  it("a screen watcher that never fires is backed up by the heartbeat", function()
    local sim = laptopOwns()
    sim:entry("laptop").screenWatcher.watchers[1]:stop()
    sim:unplug("laptop")
    sim:advance(5)
    assert.equal("laptop", sim:owner("laptop"))
    sim:advance(30)
    assert.equal("desk-mini", sim:owner("laptop"))
  end)

  it("R3b laptop gone: home takes over after the alive window", function()
    local sim = laptopOwns()
    sim:partition("laptop", true)
    sim:advance(60) -- the laptop was last heard around t=2 s: still within 3 heartbeats
    assert.equal("laptop", sim:owner("desk-mini"))
    assert.is_true(sim:mirrored("desk-mini"))
    sim:advance(65) -- the heartbeat after the 90 s window has passed
    assert.equal("desk-mini", sim:owner("desk-mini"))
    assert.is_false(sim:mirrored("desk-mini"))
    assert.equal(0, sim:ddcCalls("desk-mini"))
    assert.equal(1, #logged(sim, "desk-mini", "i", "left: owner laptop and every node with control are gone"))
  end)

  it("R3b does nothing while the owner is alive or another controller is", function()
    local sim = laptopOwns()
    sim:advance(300)
    assert.equal("laptop", sim:owner("desk-mini"))
    assert.same({}, logged(sim, "desk-mini", "i", "taking ownership"))
  end)

  it("R3b does not take over while another node with control is alive", function()
    local sim = Sim.new({
      nodes = { "desk-mini", "laptop", "studio" }, home = "desk-mini",
      monitor = {
        inputs = ALL_INPUTS, mode = "sticky", acceptsInactive = true, input = 15,
        control = { "laptop", "studio" }, noDdc = { "desk-mini" },
      },
    })
    sim:start()
    sim:advance(1)
    sim:activate("laptop")
    sim:advance(1)
    sim:partition("laptop", true)
    sim:advance(300) -- the owner is long gone, studio still answers every heartbeat
    assert.equal("laptop", sim:owner("desk-mini"))
    assert.same({}, logged(sim, "desk-mini", "i", "taking ownership"))
  end)

  it("R3b only on home", function()
    local sim = Sim.new({
      nodes = { "desk-mini", "laptop", "studio" }, home = "desk-mini",
      whenAway = { ["desk-mini"] = "mirror", studio = "mirror" },
      monitor = {
        inputs = ALL_INPUTS, mode = "sticky", acceptsInactive = true, input = 15,
        control = { "laptop" }, noDdc = { "desk-mini", "studio" },
      },
    })
    sim:start()
    sim:advance(1)
    sim:activate("laptop")
    sim:advance(1)
    assert.is_true(sim:mirrored("studio"))
    sim:partition("laptop", true)
    sim:advance(125)
    assert.equal("desk-mini", sim:owner("desk-mini"))
    assert.equal(1, #logged(sim, "desk-mini", "i", "left: owner laptop and every node with control are gone"))
    assert.same({}, logged(sim, "studio", "i", "taking ownership"))
    assert.equal(0, sim:ddcCalls("studio"))
  end)
end)

-- A reload of the home node (no DDC, whenAway mirror) while the laptop owns the display: the new process has
-- an empty state and has heard nobody yet. It must not take the "no controller reachable" shortcut before
-- discovery had a chance; it has to ask the laptop once the laptop is heard.
describe("reload of a node without DDC before discovery", function()
  local function laptopOwns()
    local sim = Sim.new({
      nodes = { "desk-mini", "laptop" },
      home = "desk-mini",
      whenAway = { ["desk-mini"] = "mirror" },
      monitor = {
        inputs = { ["desk-mini"] = 17, laptop = 21 }, mode = "sticky", acceptsInactive = true,
        control = { "laptop" }, noDdc = { "desk-mini" },
      },
    })
    sim:start()
    sim:advance(1)
    sim:activate("laptop")
    sim:advance(1)
    assert.equal(21, sim:input())
    assert.is_true(sim:mirrored("desk-mini"))
    return sim
  end

  -- Hammerspoon reload: a new process, and the mirror of the previous run is still there. Discovery is
  -- delayed: neither node hears of the other until sim:announce().
  local function reload(sim, o)
    o = o or {}
    sim:node("desk-mini"):stop()
    sim.mirroring["desk-mini"] = true -- a reload does not run stop(): the mirror survives
    sim.mute["desk-mini"], sim.mute.laptop = true, true
    if o.unlocked then
      sim:setLocked("desk-mini", false)
      sim:setIdle("desk-mini", 0)
    end
    sim:restart("desk-mini")
    return {
      mirror = sim:mirrorCalls("desk-mini").mirror,
      unmirror = sim:mirrorCalls("desk-mini").unmirror,
      requests = requests(sim, "desk-mini"),
    }
  end

  -- The laptop's Bonjour announcement reaches desk-mini.
  local function announce(sim)
    sim.mute["desk-mini"], sim.mute.laptop = nil, nil
    sim:hello("laptop")
  end

  local triggers = {
    { name = "an active start", reload = { unlocked = true }, act = function() end },
    { name = "an unlock right after start", act = function(sim) sim:activate("desk-mini") end },
    { name = "claim() right after start", act = function(sim) assert.is_true(sim:node("desk-mini"):claim()) end },
  }

  for _, t in ipairs(triggers) do
    it("D1 " .. t.name .. " asks the laptop once it is heard instead of assuming the display is here", function()
      local sim = laptopOwns()
      local before = reload(sim, t.reload)
      t.act(sim)
      sim:advance(1.5)
      assert.is_nil(sim:owner("desk-mini"))
      assert.is_true(sim:mirrored("desk-mini"))
      announce(sim)
      sim:advance(1)
      assert.same({}, logged(sim, "desk-mini", "i", "no controller reachable"))
      assert.equal(17, sim:input())
      allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
      local sent = sim:sent({ from = "desk-mini", type = "request" })
      assert.equal(before.requests + 1, #sent)
      assert.equal("laptop", sent[#sent].to)
      assert.same({ display = "left", to = "desk-mini" }, sent[#sent].body)
      assert.is_false(sim:mirrored("desk-mini"))
      assert.equal(before.unmirror + 1, sim:mirrorCalls("desk-mini").unmirror)
      assert.equal(before.mirror, sim:mirrorCalls("desk-mini").mirror)
      assert.equal(0, sim:ddcCalls("desk-mini"))
      sim:advance(30)
      assert.equal(0, sim:notified("claim-failed"))
      assert.same({}, sim:node("desk-mini").intents)
    end)
  end

  it("D2 the suspected mirror is kept past the grace period while the claim waits for discovery", function()
    local sim = laptopOwns()
    local before = reload(sim, { unlocked = true })
    sim:advance(7) -- longer than the 5 s grace period
    assert.is_true(sim:mirrored("desk-mini"))
    assert.equal(before.unmirror, sim:mirrorCalls("desk-mini").unmirror)
    announce(sim)
    sim:advance(1)
    assert.equal(17, sim:input())
    allOwners(sim, { "desk-mini", "laptop" }, "desk-mini")
    assert.is_false(sim:mirrored("desk-mini"))
    assert.equal(before.unmirror + 1, sim:mirrorCalls("desk-mini").unmirror)
    assert.equal(before.mirror, sim:mirrorCalls("desk-mini").mirror)
  end)

  it("D3 nobody is ever heard: the display is assumed here after the last attempt, without an error", function()
    local sim = laptopOwns()
    sim:partition("laptop", true)
    local before = reload(sim, { unlocked = true })
    sim:advance(20) -- the fifth attempt is at 2 + 4 + 8 + 8 = 22 s
    assert.is_nil(sim:owner("desk-mini"))
    assert.is_true(sim:mirrored("desk-mini"))
    assert.same({}, logged(sim, "desk-mini", "i", "no controller reachable"))
    sim:advance(3)
    assert.equal("desk-mini", sim:owner("desk-mini"))
    assert.equal(1, #logged(sim, "desk-mini", "i", "no controller reachable for left"))
    assert.same({}, logged(sim, "desk-mini", "e", "cannot claim"))
    assert.equal(0, sim:notified("claim-failed"))
    assert.same({}, sim:node("desk-mini").intents)
    assert.is_false(sim:mirrored("desk-mini"))
    assert.equal(before.unmirror + 1, sim:mirrorCalls("desk-mini").unmirror)
    assert.equal(0, sim:ddcCalls("desk-mini"))
  end)

  it("D4 a lock while the claim waits for discovery ends the wait and stops the suspected mirror", function()
    local sim = laptopOwns()
    sim:partition("laptop", true)
    local before = reload(sim, { unlocked = true })
    sim:advance(7)
    assert.is_true(sim:mirrored("desk-mini"))
    sim:lock("desk-mini")
    assert.is_false(sim:mirrored("desk-mini"))
    assert.equal(before.unmirror + 1, sim:mirrorCalls("desk-mini").unmirror)
    assert.same({}, sim:node("desk-mini").intents)
  end)
end)

-- The laptop is away from home: the monitor is not connected to it and no other node is on the network. The
-- claim keeps its retry schedule (on a detaching monitor "not visible" is also normal while another node shows
-- its input, and right after a wake the network may come up late), but its end is not an error.
describe("claim with the display absent and nobody reachable", function()
  -- Lines of `node` at `level` (all of them).
  local function lines(sim, node, level)
    local out = {}
    for _, line in ipairs(sim.logLines) do
      local who, lvl, msg = line:match("^(%S+) (%a) (.*)$")
      if who == node and lvl == level then out[#out + 1] = msg end
    end
    return out
  end

  local function laptopAlone()
    local sim = make({ delayed = true }) -- detaching monitor on desk-mini's input: not visible to the laptop
    sim:start("laptop")
    sim:advance(1)
    return sim
  end

  it("Q1 ends after the full retry schedule with one info line, no error and no notification", function()
    local sim = laptopAlone()
    local infoBefore = #lines(sim, "laptop", "i")
    sim:activate("laptop")
    sim:advance(21) -- the fifth attempt is at 22 s
    assert.same({ "active (screensDidUnlock)" }, { table.unpack(lines(sim, "laptop", "i"), infoBefore + 1) })
    sim:advance(10)
    assert.same({}, lines(sim, "laptop", "e"))
    assert.same({}, lines(sim, "laptop", "w"))
    assert.equal(0, sim:notified("claim-failed"))
    assert.same({
      "active (screensDidUnlock)",
      "left is not connected here and no other node is reachable; not claiming",
    }, { table.unpack(lines(sim, "laptop", "i"), infoBefore + 1) })
    assert.equal(5, #logged(sim, "laptop", "d", "no alive peer to ask for left")) -- the retries are unchanged
    assert.is_nil(sim:owner("laptop"))
    assert.equal(15, sim:input())
    assert.is_true(sim:node("laptop").intents.left.exhausted) -- as before: exhausted, restarted by the next unlock
  end)

  it("Q1b every unlock gets the same quiet end, never a notification", function()
    local sim = laptopAlone()
    for _ = 1, 3 do
      sim:activate("laptop")
      sim:advance(30)
      sim:lock("laptop")
      sim:advance(1)
    end
    assert.equal(0, sim:notified("claim-failed"))
    assert.same({}, lines(sim, "laptop", "e"))
    assert.equal(3, #logged(sim, "laptop", "i", "not connected here and no other node is reachable"))
  end)

  it("Q2 a peer that is alive but cannot help still makes it an error with a notification", function()
    local sim = make()
    sim.monitor.failing = true -- desk-mini sees the display, but its switch fails
    sim:activate("laptop")
    sim:advance(30)
    assert.is_true(sim:node("laptop"):alive("desk-mini"))
    assert.equal(1, #logged(sim, "laptop", "e", "cannot claim left"))
    assert.equal(1, sim:notified("claim-failed", "laptop"))
    assert.same({}, logged(sim, "laptop", "i", "not connected here"))
  end)

  it("Q3 a peer that turns up during the retries grants the claim as before", function()
    local sim = laptopAlone()
    sim:activate("laptop")
    sim:advance(3)
    sim:start("desk-mini")
    sim:advance(10)
    assert.equal(16, sim:input())
    allOwners(sim, { "desk-mini", "laptop" }, "laptop")
    assert.equal(0, sim:notified("claim-failed"))
    assert.same({}, logged(sim, "laptop", "i", "not connected here"))
    assert.same({}, sim:node("laptop").intents)
  end)
end)

-- Every successful switch caused by a node is logged once at info level by each node involved.
describe("switch log lines", function()
  local function switchLines(sim, node)
    return logged(sim, node, "i", "switched")
  end

  it("W1 a pull on unlock: one line on the claiming node, none elsewhere", function()
    local sim = make({ mode = "sticky", acceptsInactive = true })
    sim:activate("laptop")
    sim:advance(1)
    assert.same({ "switched left to laptop (screensDidUnlock)" }, switchLines(sim, "laptop"))
    assert.same({}, switchLines(sim, "desk-mini"))
  end)

  it("W1b a manual claim (hotkey) names itself as the reason", function()
    local sim = make({ mode = "sticky", acceptsInactive = true })
    sim:node("laptop"):claim()
    sim:advance(1)
    assert.same({ "switched left to laptop (manual claim)" }, switchLines(sim, "laptop"))
  end)

  it("W2 a request: the controller logs the switch it served, the requester the grant", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    sim:activate("desk-mini")
    sim:advance(5)
    assert.equal(15, sim:input())
    -- detaching monitor: each claim goes through a request to the node that sees the display
    assert.same({ "switched left to laptop for laptop", "left switched to desk-mini by laptop" },
      switchLines(sim, "desk-mini"))
    assert.same({ "left switched to laptop by desk-mini", "switched left to desk-mini for desk-mini" },
      switchLines(sim, "laptop"))
  end)

  it("W3 a release on lock: one line on the releasing node", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    sim:lock("laptop")
    sim:advance(1)
    assert.same({ "left switched to laptop by desk-mini", "switched left to desk-mini (release: screensDidLock)" },
      switchLines(sim, "laptop"))
    assert.same({ "switched left to laptop for laptop" }, switchLines(sim, "desk-mini"))
  end)

  it("W3b a release on sleep (synchronous): one line", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    sim:sleep("laptop")
    assert.equal(1, #logged(sim, "laptop", "i", "switched left to desk-mini (release: systemWillSleep)"))
  end)

  it("W4 a delegated release from a node outside control: 'via' on it, 'for' on the controller", function()
    local sim = make({
      mode = "sticky", acceptsInactive = true, control = { "laptop" }, noDdc = { "desk-mini" },
    })
    sim:activate("laptop")
    sim:advance(1)
    sim:activate("desk-mini")
    sim:advance(1)
    sim:lock("desk-mini")
    sim:advance(1)
    assert.equal(16, sim:input())
    assert.same({
      "left switched to desk-mini by laptop",
      "left switched to laptop via laptop (release: screensDidLock)",
    }, switchLines(sim, "desk-mini"))
    assert.same({
      "switched left to laptop (screensDidUnlock)",
      "switched left to desk-mini for desk-mini",
      "switched left to laptop for desk-mini",
    }, switchLines(sim, "laptop"))
  end)

  for _, burst in ipairs({
    { name = "lock then sleep", run = function(sim) sim:lock("laptop") sim:sleep("laptop") end },
    { name = "lid close then lock", lid = true, run = function(sim) sim:lid("laptop", true) sim:lock("laptop") end },
    { name = "lock twice", run = function(sim) sim:lock("laptop") sim:lock("laptop") end },
  }) do
    it("W5 an inactivity burst (" .. burst.name .. ") logs one switch line for its one switch", function()
      local sim = make({ lid = burst.lid })
      sim:activate("laptop")
      sim:advance(1)
      local applied = sim.monitor.applied
      burst.run(sim)
      sim:advance(5)
      assert.equal(applied + 1, sim.monitor.applied)
      assert.equal(1, #logged(sim, "laptop", "i", "switched left to desk-mini (release: "))
    end)
  end

  it("W6 a pull that lands after going inactive: its own line, then the release line", function()
    local sim = make({ mode = "sticky", acceptsInactive = true })
    sim:activate("laptop")
    sim:lock("laptop") -- the pull is still in flight
    sim:advance(5)
    assert.equal(15, sim:input())
    assert.same({ "claim of left landed after going inactive, releasing it" }, logged(sim, "laptop", "i", "landed"))
    assert.same({ "switched left to desk-mini (release: late claim)" }, switchLines(sim, "laptop"))
  end)

  it("W7 failures and suppressed releases add no switch line", function()
    local sim = make()
    sim:activate("laptop")
    sim:advance(1)
    sim.monitor.input = 15 -- switched away behind the laptop's back: the release finds it not visible
    sim:lock("laptop")
    sim:advance(5)
    assert.same({ "left switched to laptop by desk-mini" }, switchLines(sim, "laptop"))
    assert.equal(1, #logged(sim, "laptop", "i", "already handed over"))
  end)
end)
