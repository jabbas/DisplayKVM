local json = require("dkjson")
local State = dofile("state.lua")

describe("State", function()
  local s
  before_each(function() s = State.new() end)

  describe("owner register", function()
    it("sets an owner on an empty state", function()
      assert.is_true(s:setOwner("left", "laptop", 100))
      local node, ts = s:owner("left")
      assert.equal("laptop", node)
      assert.equal(100, ts)
    end)

    it("returns nil for an unknown display", function()
      assert.is_nil(s:owner("left"))
    end)

    it("ignores an older write", function()
      s:setOwner("left", "laptop", 100)
      assert.is_false(s:setOwner("left", "desk-mini", 90))
      assert.equal("laptop", (s:owner("left")))
    end)

    it("takes a newer write", function()
      s:setOwner("left", "laptop", 100)
      assert.is_true(s:setOwner("left", "desk-mini", 110))
      local node, ts = s:owner("left")
      assert.equal("desk-mini", node)
      assert.equal(110, ts)
    end)

    it("breaks a ts tie with the lexicographically greater node", function()
      s:setOwner("left", "desk-mini", 100)
      assert.is_true(s:setOwner("left", "laptop", 100))
      assert.equal("laptop", (s:owner("left")))
    end)

    it("breaks a ts tie the same way in the opposite order", function()
      s:setOwner("left", "laptop", 100)
      assert.is_false(s:setOwner("left", "desk-mini", 100))
      assert.equal("laptop", (s:owner("left")))
    end)

    it("reports no change for an identical record", function()
      s:setOwner("left", "laptop", 100)
      assert.is_false(s:setOwner("left", "laptop", 100))
    end)
  end)

  describe("ownerWins", function()
    it("compares ts first, then node", function()
      assert.is_true(State.ownerWins({ node = "a", ts = 2 }, { node = "z", ts = 1 }))
      assert.is_false(State.ownerWins({ node = "z", ts = 1 }, { node = "a", ts = 2 }))
      assert.is_true(State.ownerWins({ node = "laptop", ts = 1 }, { node = "desk-mini", ts = 1 }))
      assert.is_false(State.ownerWins({ node = "desk-mini", ts = 1 }, { node = "laptop", ts = 1 }))
      assert.is_false(State.ownerWins({ node = "laptop", ts = 1 }, { node = "laptop", ts = 1 }))
    end)

    it("on a full tie the assumed record wins over the confirmed one, never the other way", function()
      assert.is_true(State.ownerWins({ node = "a", ts = 1, assumed = true }, { node = "a", ts = 1 }))
      assert.is_false(State.ownerWins({ node = "a", ts = 1 }, { node = "a", ts = 1, assumed = true }))
      assert.is_false(State.ownerWins({ node = "a", ts = 1, assumed = true }, { node = "a", ts = 1, assumed = true }))
      -- ts and node still come first
      assert.is_true(State.ownerWins({ node = "a", ts = 2 }, { node = "a", ts = 1, assumed = true }))
      assert.is_true(State.ownerWins({ node = "b", ts = 1 }, { node = "a", ts = 1, assumed = true }))
    end)
  end)

  -- 0.2.3: an owner record written by a recovery rule without any DDC (R3a, R3b) is marked `assumed`.
  describe("assumed owner records", function()
    it("is false for a plain write and for an unknown display", function()
      s:setOwner("left", "laptop", 100)
      assert.is_false(s:assumed("left"))
      assert.is_false(s:assumed("right"))
    end)

    it("is kept with the record and cleared by a newer confirmed write", function()
      assert.is_true(s:setOwner("left", "desk-mini", 100, true))
      assert.is_true(s:assumed("left"))
      assert.equal("desk-mini", (s:owner("left")))
      assert.is_true(s:setOwner("left", "desk-mini", 110))
      assert.is_false(s:assumed("left"))
    end)

    it("goes into the snapshot only when set", function()
      s:setOwner("left", "desk-mini", 100, true)
      s:setOwner("right", "laptop", 100)
      local snap = s:snapshot()
      assert.same({ node = "desk-mini", ts = 100, assumed = true }, snap.owner.left)
      assert.same({ node = "laptop", ts = 100 }, snap.owner.right)
    end)

    it("survives merge and a JSON round trip", function()
      s:setOwner("left", "desk-mini", 100, true)
      local other = State.new()
      other:merge(json.decode(json.encode(s:snapshot())))
      assert.is_true(other:assumed("left"))
    end)

    it("is not cleared by a peer that sends the same record back without the flag (0.2.2)", function()
      s:setOwner("left", "desk-mini", 100, true)
      assert.same({}, s:merge({ owner = { left = { node = "desk-mini", ts = 100 } } }))
      assert.is_true(s:assumed("left"))
    end)

    it("takes the flag of the same record when it arrives later", function()
      s:setOwner("left", "desk-mini", 100)
      assert.equal(1, #s:merge({ owner = { left = { node = "desk-mini", ts = 100, assumed = true } } }))
      assert.is_true(s:assumed("left"))
    end)

    it("merges a full tie commutatively and in any order of three snapshots", function()
      local records = {
        { node = "desk-mini", ts = 100, assumed = true },
        { node = "desk-mini", ts = 100 },
        { node = "laptop", ts = 100 },
        { node = "desk-mini", ts = 90, assumed = true },
      }
      local function snap(r) return { owner = { left = r } } end
      -- every pair, both ways
      for i = 1, #records do
        for j = 1, #records do
          local ab, ba = State.new(), State.new()
          ab:merge(snap(records[i])) ab:merge(snap(records[j]))
          ba:merge(snap(records[j])) ba:merge(snap(records[i]))
          assert.same(ab:snapshot(), ba:snapshot(), i .. "," .. j)
        end
      end
      -- every order of the first three, folded one by one and pre-merged in pairs
      local orders = { { 1, 2, 3 }, { 1, 3, 2 }, { 2, 1, 3 }, { 2, 3, 1 }, { 3, 1, 2 }, { 3, 2, 1 } }
      local expected
      for _, o in ipairs(orders) do
        local folded = State.new()
        for _, k in ipairs(o) do folded:merge(snap(records[k])) end
        local pair = State.new()
        pair:merge(snap(records[o[2]])) pair:merge(snap(records[o[3]]))
        local grouped = State.new()
        grouped:merge(snap(records[o[1]])) grouped:merge(pair:snapshot())
        expected = expected or folded:snapshot()
        assert.same(expected, folded:snapshot())
        assert.same(expected, grouped:snapshot())
      end
      assert.same({ node = "laptop", ts = 100 }, expected.owner.left)
      -- without the greater node name, the assumed record of the tie wins
      local two = State.new()
      two:merge(snap(records[2])) two:merge(snap(records[1]))
      assert.is_true(two:assumed("left"))
    end)

    it("treats a non-boolean flag as not assumed", function()
      s:merge({ owner = { left = { node = "desk-mini", ts = 100, assumed = "yes" } } })
      assert.equal("desk-mini", (s:owner("left")))
      assert.is_false(s:assumed("left"))
    end)
  end)

  describe("presence register", function()
    it("sets presence on an empty state", function()
      assert.is_true(s:setPresence("laptop", true, 50, 100))
      assert.same({ active = true, since = 50, ts = 100 }, s:presence("laptop"))
    end)

    it("returns nil for an unknown node", function()
      assert.is_nil(s:presence("laptop"))
    end)

    it("takes a newer ts", function()
      s:setPresence("laptop", true, 50, 100)
      assert.is_true(s:setPresence("laptop", false, 120, 120))
      assert.same({ active = false, since = 120, ts = 120 }, s:presence("laptop"))
    end)

    it("ignores an older ts", function()
      s:setPresence("laptop", true, 50, 100)
      assert.is_false(s:setPresence("laptop", false, 90, 90))
      assert.is_true(s:presence("laptop").active)
    end)

    it("keeps the existing record on equal ts", function()
      s:setPresence("laptop", true, 50, 100)
      assert.is_false(s:setPresence("laptop", false, 99, 100))
      assert.same({ active = true, since = 50, ts = 100 }, s:presence("laptop"))
    end)

    it("returns a copy of the record", function()
      s:setPresence("laptop", true, 50, 100)
      s:presence("laptop").active = false
      assert.is_true(s:presence("laptop").active)
    end)
  end)

  describe("merge", function()
    local function build_a()
      local a = State.new()
      a:setOwner("left", "desk-mini", 100)
      a:setOwner("right", "laptop", 200)
      a:setPresence("laptop", true, 10, 100)
      a:setPresence("studio", false, 20, 300)
      return a
    end
    local function build_b()
      local b = State.new()
      b:setOwner("left", "laptop", 100)
      b:setOwner("right", "desk-mini", 150)
      b:setOwner("third", "studio", 5)
      b:setPresence("laptop", false, 90, 200)
      b:setPresence("studio", true, 5, 250)
      return b
    end

    it("is idempotent", function()
      local a, b = build_a(), build_b()
      local first = a:merge(b:snapshot())
      assert.is_true(#first > 0)
      assert.same({}, a:merge(b:snapshot()))
    end)

    it("is commutative", function()
      local ab = build_a()
      ab:merge(build_b():snapshot())
      local ba = build_b()
      ba:merge(build_a():snapshot())
      assert.same(ab:snapshot(), ba:snapshot())
    end)

    it("returns changes with kind and key", function()
      local a, b = build_a(), build_b()
      local changes = a:merge(b:snapshot())
      table.sort(changes, function(x, y)
        if x.kind ~= y.kind then return x.kind < y.kind end
        return x.key < y.key
      end)
      assert.same({
        { kind = "owner", key = "left" },
        { kind = "owner", key = "third" },
        { kind = "presence", key = "laptop" },
      }, changes)
    end)

    it("returns an empty list when nothing changes", function()
      local a = build_a()
      assert.same({}, a:merge(a:snapshot()))
    end)

    it("tolerates an empty or malformed snapshot", function()
      local a = build_a()
      local before = a:snapshot()
      assert.same({}, a:merge({}))
      assert.same({}, a:merge({ owner = json.decode("[]"), presence = json.decode("[]") }))
      assert.same({}, a:merge({ owner = { left = "bad" }, presence = { laptop = { active = "yes" } } }))
      assert.same(before, a:snapshot())
    end)
  end)

  describe("snapshot", function()
    it("has the documented shape", function()
      s:setOwner("left", "laptop", 100)
      s:setPresence("laptop", true, 50, 100)
      assert.same({
        owner = { left = { node = "laptop", ts = 100 } },
        presence = { laptop = { active = true, since = 50, ts = 100 } },
      }, s:snapshot())
    end)

    it("is a deep copy", function()
      s:setOwner("left", "laptop", 100)
      s:setPresence("laptop", true, 50, 100)
      local snap = s:snapshot()
      snap.owner.left.node = "hacked"
      snap.owner.right = { node = "x", ts = 1 }
      snap.presence.laptop.active = false
      assert.equal("laptop", (s:owner("left")))
      assert.is_nil(s:owner("right"))
      assert.is_true(s:presence("laptop").active)
    end)
  end)

  describe("fromSnapshot", function()
    it("round-trips a snapshot", function()
      s:setOwner("left", "laptop", 100)
      s:setPresence("laptop", true, 50, 100)
      assert.same(s:snapshot(), State.fromSnapshot(s:snapshot()):snapshot())
    end)

    it("accepts empty maps", function()
      local st = State.fromSnapshot({ owner = {}, presence = {} })
      assert.same({ owner = {}, presence = {} }, st:snapshot())
    end)

    it("accepts [] decoded from JSON as an empty map", function()
      local st = State.fromSnapshot({ owner = json.decode("[]"), presence = json.decode("[]") })
      assert.same({ owner = {}, presence = {} }, st:snapshot())
    end)

    it("accepts missing fields and nil", function()
      assert.same({ owner = {}, presence = {} }, State.fromSnapshot({}):snapshot())
      assert.same({ owner = {}, presence = {} }, State.fromSnapshot(nil):snapshot())
    end)

    it("skips records of invalid types", function()
      local st = State.fromSnapshot({
        owner = {
          left = { node = "laptop", ts = 1 },
          bad1 = { node = 5, ts = 1 },
          bad2 = { node = "x", ts = "1" },
          bad3 = "str",
        },
        presence = {
          laptop = { active = true, since = 1, ts = 2 },
          bad1 = { active = "yes", since = 1, ts = 2 },
          bad2 = { active = true, since = "1", ts = 2 },
          bad3 = { active = true, since = 1 },
        },
      })
      assert.same({
        owner = { left = { node = "laptop", ts = 1 } },
        presence = { laptop = { active = true, since = 1, ts = 2 } },
      }, st:snapshot())
    end)
  end)
end)
