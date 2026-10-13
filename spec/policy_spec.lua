local State = dofile("state.lua")
local Policy = dofile("policy.lua")

describe("Policy", function()
  local cfg, state

  local function alive_all() return true end

  before_each(function()
    cfg = {
      node = "laptop",
      displays = {
        left = {
          inputs = { ["desk-mini"] = 15, laptop = 16, studio = 17 },
          home = "desk-mini", pull = true, match = "X",
        },
        right = {
          inputs = { ["desk-mini"] = 1, laptop = 2 },
          home = "desk-mini", pull = true, match = "Y",
        },
      },
    }
    state = State.new()
  end)

  describe("onActive", function()
    it("claims every display with an input for me when owned by someone else", function()
      state:setOwner("left", "desk-mini", 100)
      assert.same({ "left", "right" }, Policy.onActive(state, cfg, "laptop"))
    end)

    it("ignores the recorded owner, even when it is already me", function()
      state:setOwner("left", "laptop", 100)
      state:setOwner("right", "laptop", 100)
      assert.same({ "left", "right" }, Policy.onActive(state, cfg, "laptop"))
    end)

    it("works with no recorded owner", function()
      assert.same({ "left", "right" }, Policy.onActive(state, cfg, "laptop"))
    end)

    it("skips displays without an input for me", function()
      assert.same({ "left" }, Policy.onActive(state, cfg, "studio"))
    end)

    it("returns an empty list when no display has an input for me", function()
      assert.same({}, Policy.onActive(state, cfg, "stranger"))
    end)
  end)

  describe("onInactive", function()
    before_each(function()
      state:setOwner("left", "laptop", 100)
      state:setOwner("right", "laptop", 100)
    end)

    it("hands each display to the most recently activated peer that has an input", function()
      state:setPresence("studio", true, 200, 200)
      state:setPresence("desk-mini", true, 100, 100)
      assert.same({
        { display = "left", target = "studio" },
        { display = "right", target = "desk-mini" },
      }, Policy.onInactive(state, cfg, "laptop", alive_all))
    end)

    it("falls back to home when nobody else is active", function()
      assert.same({
        { display = "left", target = "desk-mini" },
        { display = "right", target = "desk-mini" },
      }, Policy.onInactive(state, cfg, "laptop", alive_all))
    end)

    it("falls back to home when the only active peer is inactive in presence", function()
      state:setPresence("studio", false, 200, 200)
      assert.same({
        { display = "left", target = "desk-mini" },
        { display = "right", target = "desk-mini" },
      }, Policy.onInactive(state, cfg, "laptop", alive_all))
    end)

    it("skips active peers that are not alive", function()
      state:setPresence("studio", true, 200, 200)
      local alive = function(n) return n ~= "studio" end
      assert.same({
        { display = "left", target = "desk-mini" },
        { display = "right", target = "desk-mini" },
      }, Policy.onInactive(state, cfg, "laptop", alive))
    end)

    it("hands over to home even when home is not alive", function()
      local alive = function() return false end
      assert.same({
        { display = "left", target = "desk-mini" },
        { display = "right", target = "desk-mini" },
      }, Policy.onInactive(state, cfg, "laptop", alive))
    end)

    it("does nothing when me is home and nobody else is active", function()
      cfg.node = "desk-mini"
      state:setOwner("left", "desk-mini", 200)
      state:setOwner("right", "desk-mini", 200)
      assert.same({}, Policy.onInactive(state, cfg, "desk-mini", alive_all))
    end)

    it("still hands over to an active peer when me is home", function()
      state:setOwner("left", "desk-mini", 200)
      state:setOwner("right", "desk-mini", 200)
      state:setPresence("laptop", true, 300, 300)
      assert.same({
        { display = "left", target = "laptop" },
        { display = "right", target = "laptop" },
      }, Policy.onInactive(state, cfg, "desk-mini", alive_all))
    end)

    it("breaks a tie on since with the greater node name", function()
      state:setPresence("studio", true, 200, 200)
      state:setPresence("desk-mini", true, 200, 201)
      assert.same({
        { display = "left", target = "studio" },
        { display = "right", target = "desk-mini" },
      }, Policy.onInactive(state, cfg, "laptop", alive_all))
    end)

    it("only handles displays owned by me", function()
      state:setOwner("left", "desk-mini", 200)
      assert.same({ { display = "right", target = "desk-mini" } },
        Policy.onInactive(state, cfg, "laptop", alive_all))
    end)

    it("handles nothing when there is no recorded owner", function()
      assert.same({}, Policy.onInactive(State.new(), cfg, "laptop", alive_all))
    end)

    it("never targets me", function()
      state:setPresence("laptop", true, 500, 500)
      assert.same({
        { display = "left", target = "desk-mini" },
        { display = "right", target = "desk-mini" },
      }, Policy.onInactive(state, cfg, "laptop", alive_all))
    end)
  end)
end)
