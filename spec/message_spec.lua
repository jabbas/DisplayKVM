local json = require("dkjson")
local Message = dofile("message.lua")

describe("Message", function()
  local clock, counter, desk, laptop

  local function hmac(k, d) return "H" .. #k .. ":" .. d end

  local function make(node, instance)
    return Message.new({
      secret = "shared-secret",
      node = node,
      instance = instance,
      hmac = hmac,
      now = function() return clock end,
      random = function(n)
        counter = counter + 1
        return string.format("%0" .. (n * 2) .. "x", counter)
      end,
      codec = { encode = json.encode, decode = json.decode },
      window = 30000,
      nonceTtl = 60000,
    })
  end

  before_each(function()
    clock = 1000000
    counter = 0
    desk = make("desk-mini", "inst-desk")
    laptop = make("laptop", "inst-laptop")
  end)

  it("keeps the secret out of the object", function()
    local deepContains = dofile("spec/support/deep.lua")
    desk:build("state", {})
    assert.is_false(deepContains(desk, "shared-secret"))
  end)

  describe("build", function()
    it("produces the envelope and signs the raw string", function()
      local raw, sig = desk:build("state", { x = 1 })
      assert.are.equal(hmac("shared-secret", raw), sig)
      local env = json.decode(raw)
      assert.are.equal(1, env.v)
      assert.are.equal("desk-mini", env.from)
      assert.are.equal("inst-desk", env.instance)
      assert.are.equal(clock, env.ts)
      assert.are.equal(32, #env.nonce)
      assert.are.equal("state", env.type)
      assert.are.same({ x = 1 }, env.body)
    end)

    it("uses a fresh nonce each time", function()
      local a = json.decode((desk:build("state", {})))
      local b = json.decode((desk:build("state", {})))
      assert.are_not.equal(a.nonce, b.nonce)
    end)
  end)

  describe("verify", function()
    it("accepts a message from a peer", function()
      local msg, reason = laptop:verify(desk:build("state", { x = 1 }))
      assert.is_nil(reason)
      assert.are.equal("state", msg.type)
      assert.are.equal("desk-mini", msg.from)
      assert.are.equal("inst-desk", msg.instance)
      assert.are.equal(1, msg.body.x)
    end)

    it("rejects a tampered raw body", function()
      local raw, sig = desk:build("state", { x = 1 })
      local i = raw:find("1}", 1, true)
      local tampered = raw:sub(1, i - 1) .. "2" .. raw:sub(i + 1)
      local msg, reason = laptop:verify(tampered, sig)
      assert.is_nil(msg)
      assert.are.equal("bad-signature", reason)
    end)

    it("rejects a missing signature", function()
      local raw = desk:build("state", {})
      local msg, reason = laptop:verify(raw, nil)
      assert.is_nil(msg)
      assert.are.equal("bad-signature", reason)
    end)

    it("rejects a signature made with another secret", function()
      local other = Message.new({
        secret = "other", node = "desk-mini", instance = "i", hmac = hmac,
        now = function() return clock end, random = function() return string.rep("0", 32) end,
        codec = { encode = json.encode, decode = json.decode },
      })
      local msg, reason = laptop:verify(other:build("state", {}))
      assert.is_nil(msg)
      assert.are.equal("bad-signature", reason)
    end)

    it("accepts a timestamp exactly at the window edge", function()
      local raw, sig = desk:build("state", {})
      clock = clock + 30000
      assert.is_table((laptop:verify(raw, sig)))
    end)

    it("rejects a stale message and reports the sender", function()
      local raw, sig = desk:build("state", {})
      clock = clock + 30001
      local msg, reason, from = laptop:verify(raw, sig)
      assert.is_nil(msg)
      assert.are.equal("stale", reason)
      assert.are.equal("desk-mini", from)
    end)

    it("rejects a message from the future beyond the window", function()
      local raw, sig = desk:build("state", {})
      clock = clock - 30001
      local msg, reason, from = laptop:verify(raw, sig)
      assert.is_nil(msg)
      assert.are.equal("stale", reason)
      assert.are.equal("desk-mini", from)
    end)

    it("rejects a replay", function()
      local raw, sig = desk:build("state", {})
      assert.is_table((laptop:verify(raw, sig)))
      local msg, reason = laptop:verify(raw, sig)
      assert.is_nil(msg)
      assert.are.equal("replay", reason)
    end)

    it("forgets nonces after the TTL", function()
      assert.is_table((laptop:verify(desk:build("state", {}))))
      assert.are.equal(1, laptop:_nonceCount())
      clock = clock + 60000
      assert.is_table((laptop:verify(desk:build("state", {}))))
      assert.are.equal(2, laptop:_nonceCount())
      clock = clock + 1
      assert.is_table((laptop:verify(desk:build("state", {}))))
      assert.are.equal(2, laptop:_nonceCount())
      clock = clock + 60001
      assert.is_table((laptop:verify(desk:build("state", {}))))
      assert.are.equal(1, laptop:_nonceCount())
    end)

    it("does not remember nonces of rejected messages", function()
      local raw, sig = desk:build("state", {})
      laptop:verify(raw .. "x", sig)
      assert.are.equal(0, laptop:_nonceCount())
    end)

    it("rejects its own messages", function()
      local msg, reason = desk:verify(desk:build("state", {}))
      assert.is_nil(msg)
      assert.are.equal("self", reason)
    end)

    it("rejects a correctly signed non-JSON payload as malformed", function()
      local raw = "not json"
      local msg, reason = laptop:verify(raw, hmac("shared-secret", raw))
      assert.is_nil(msg)
      assert.are.equal("malformed", reason)
    end)

    it("rejects malformed envelopes", function()
      local good = {
        v = 1, from = "desk-mini", instance = "i", ts = clock, nonce = "n", type = "state", body = {},
      }
      local cases = {
        function(e) e.v = 2 end,
        function(e) e.v = nil end,
        function(e) e.from = 5 end,
        function(e) e.instance = nil end,
        function(e) e.ts = "now" end,
        function(e) e.nonce = nil end,
        function(e) e.type = 1 end,
        function(e) e.body = "text" end,
        function(e) e.body = nil end,
      }
      for i, mut in ipairs(cases) do
        local e = {}
        for k, v in pairs(good) do e[k] = v end
        mut(e)
        local raw = json.encode(e)
        local msg, reason = laptop:verify(raw, hmac("shared-secret", raw))
        assert.is_nil(msg, "case " .. i)
        assert.are.equal("malformed", reason, "case " .. i)
      end
    end)

    it("rejects JSON that is not an object", function()
      local raw = "42"
      local msg, reason = laptop:verify(raw, hmac("shared-secret", raw))
      assert.is_nil(msg)
      assert.are.equal("malformed", reason)
    end)

    it("does not raise when the codec raises", function()
      local m = Message.new({
        secret = "s", node = "a", instance = "i", hmac = hmac,
        now = function() return clock end, random = function() return "0" end,
        codec = { encode = json.encode, decode = function() error("boom") end },
      })
      local msg, reason = m:verify("x", hmac("s", "x"))
      assert.is_nil(msg)
      assert.are.equal("malformed", reason)
    end)

    it("treats non-string raw as bad-signature", function()
      local msg, reason = laptop:verify(nil, "sig")
      assert.is_nil(msg)
      assert.are.equal("bad-signature", reason)
    end)
  end)

  describe("time window hardening", function()
    -- A verifier whose codec yields an envelope with exactly the given ts, however unusual.
    local function verifyTs(ts)
      local m = Message.new({
        secret = "s", node = "laptop", instance = "i", hmac = hmac,
        now = function() return clock end, random = function() return "0" end,
        codec = {
          encode = json.encode,
          decode = function()
            return { v = 1, from = "desk-mini", instance = "i", ts = ts, nonce = "n", type = "state", body = {} }
          end,
        },
      })
      return m:verify("x", hmac("s", "x"))
    end

    it("accepts exactly now - 30000 and now + 30000", function()
      assert.is_table((verifyTs(clock - 30000)))
      assert.is_table((verifyTs(clock + 30000)))
      assert.is_table((verifyTs(clock - 30000.0)))
      assert.is_table((verifyTs(clock + 30000.0)))
    end)

    it("rejects one millisecond beyond the window as stale", function()
      for _, ts in ipairs({ clock - 30001, clock + 30001, clock - 30000.5, clock + 30000.5 }) do
        local msg, reason, from = verifyTs(ts)
        assert.is_nil(msg)
        assert.are.equal("stale", reason, tostring(ts))
        assert.are.equal("desk-mini", from)
      end
    end)

    it("rejects NaN and infinite timestamps as malformed", function()
      for _, ts in ipairs({ 0 / 0, math.huge, -math.huge }) do
        local msg, reason = verifyTs(ts)
        assert.is_nil(msg)
        assert.are.equal("malformed", reason, tostring(ts))
      end
    end)

    it("rejects huge timestamps as stale", function()
      for _, ts in ipairs({ 1e300, -1e300, math.maxinteger, math.mininteger }) do
        local msg, reason = verifyTs(ts)
        assert.is_nil(msg)
        assert.are.equal("stale", reason, tostring(ts))
      end
    end)

    it("rejects the integer whose difference to now wraps to math.mininteger", function()
      local msg, reason = verifyTs(math.mininteger + clock)
      assert.is_nil(msg)
      assert.are.equal("stale", reason)
    end)

    it("does not remember the nonce of a rejected timestamp", function()
      local m = laptop
      local raw = json.encode({ v = 1, from = "desk-mini", instance = "i", ts = clock + 99999, nonce = "n",
        type = "state", body = {} })
      assert.is_nil((m:verify(raw, hmac("shared-secret", raw))))
      assert.are.equal(0, m:_nonceCount())
    end)
  end)

  describe("new", function()
    local function new(extra)
      local deps = {
        secret = "s", node = "a", instance = "i", hmac = hmac,
        now = function() return clock end, random = function() return "0" end,
        codec = { encode = json.encode, decode = json.decode },
      }
      for k, v in pairs(extra) do deps[k] = v end
      return Message.new(deps)
    end

    it("requires nonceTtl to be at least twice the window and names both in the error", function()
      local ok, err = pcall(new, { window = 30000, nonceTtl = 59999 })
      assert.is_false(ok)
      assert.matches("nonceTtl", err)
      assert.matches("window", err)
      assert.matches("59999", err)
      assert.matches("30000", err)
      assert.is_true((pcall(new, { window = 30000, nonceTtl = 60000 })))
      assert.is_true((pcall(new, { window = 1000, nonceTtl = 5000 })))
    end)

    it("derives the default nonceTtl from a custom window", function()
      assert.is_true((pcall(new, { window = 50000 })))
      assert.is_true((pcall(new, {})))
    end)
  end)

  describe("constantTimeEqual", function()
    it("compares strings", function()
      assert.is_true(Message.constantTimeEqual("abc", "abc"))
      assert.is_false(Message.constantTimeEqual("abc", "abd"))
      assert.is_false(Message.constantTimeEqual("abc", "ab"))
      assert.is_false(Message.constantTimeEqual("ab", "abc"))
      assert.is_true(Message.constantTimeEqual("", ""))
      assert.is_false(Message.constantTimeEqual("\0abc", "\0abd"))
      assert.is_false(Message.constantTimeEqual("\255", "\0"))
      assert.is_true(Message.constantTimeEqual("\255\0\128", "\255\0\128"))
    end)

    it("returns false for non-strings", function()
      assert.is_false(Message.constantTimeEqual(nil, "a"))
      assert.is_false(Message.constantTimeEqual("a", nil))
    end)
  end)
end)
