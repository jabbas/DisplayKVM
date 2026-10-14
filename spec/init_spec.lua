local fake_hs = dofile("spec/support/fake_hs.lua")

local SECRET = string.rep("ab", 32)

local function validConfig(extra)
  local cfg = {
    secret = SECRET,
    node = "desk-mini",
    backend = function(_, _, done) done(true) end,
    displays = {
      main = { match = "DELL", inputs = { ["desk-mini"] = 15, laptop = 16 } },
    },
  }
  for k, v in pairs(extra or {}) do cfg[k] = v end
  return cfg
end

local function count(calls, name)
  local n = 0
  for _, c in ipairs(calls) do
    if c.name == name then n = n + 1 end
  end
  return n
end

describe("init", function()
  after_each(function() fake_hs.uninstall() end)

  describe("loading", function()
    it("does no work at load time", function()
      local _, calls = fake_hs.install()
      dofile("init.lua")
      assert.are.same({}, calls)
    end)

    it("init() has no side effects", function()
      local _, calls = fake_hs.install()
      local obj = dofile("init.lua")
      assert.are.equal(obj, obj:init())
      assert.are.same({}, calls)
    end)

    it("exposes the Spoon metadata", function()
      fake_hs.install()
      local obj = dofile("init.lua")
      assert.are.equal("DisplayKVM", obj.name)
      assert.are.equal("0.1.1", obj.version)
      assert.are.equal("Grzegorz Dzięgielewski <jabbas@jabbas.eu>", obj.author)
      assert.are.equal("MIT - https://opensource.org/licenses/MIT", obj.license)
      assert.are.equal("https://github.com/jabbas/DisplayKVM", obj.homepage)
    end)
  end)

  describe("configure", function()
    it("returns self and logs nothing on a valid configuration", function()
      local _, calls = fake_hs.install()
      local obj = dofile("init.lua")
      assert.are.equal(obj, obj:configure(validConfig()))
      assert.are.equal(0, count(calls, "notify.new"))
      assert.are.equal(0, count(calls, "log.e"))
    end)

    it("applies the configured log level", function()
      local _, calls = fake_hs.install()
      local obj = dofile("init.lua")
      obj:configure(validConfig({ logLevel = "debug" }))
      assert.are.equal(1, count(calls, "logger.new"))
      assert.are.equal("DisplayKVM", calls[1].args[1])
      assert.are.equal("info", calls[1].args[2])
      assert.are.equal("debug", obj._log.level)
    end)

    it("reports an invalid secret once: log.e and one notification", function()
      local _, calls = fake_hs.install()
      local obj = dofile("init.lua")
      assert.are.equal(obj, obj:configure(validConfig({ secret = "short" })))
      assert.are.equal(1, count(calls, "notify.new"))
      assert.are.equal(1, count(calls, "notify.send"))
      assert.are.equal(1, count(calls, "log.e"))
      for _, c in ipairs(calls) do
        if c.name == "notify.new" then
          assert.are.equal("DisplayKVM", c.args[1].title)
          assert.is_truthy(c.args[1].informativeText:find("secret", 1, true))
        end
      end
    end)

    it("uses the host name when no node is configured", function()
      fake_hs.install({ hostname = "laptop" })
      local obj = dofile("init.lua")
      obj:configure({
        secret = SECRET,
        backend = function() end,
        displays = { main = { match = "X", inputs = { laptop = 1, other = 2 } } },
      })
      assert.is_not_nil(obj._cfg)
      assert.are.equal("laptop", obj._cfg.node)
    end)

    it("checks a built-in backend binary through hs.fs.attributes", function()
      local _, calls = fake_hs.install()
      local obj = dofile("init.lua")
      obj:configure(validConfig({ backend = "m1ddc" }))
      assert.are.equal(1, count(calls, "notify.new"))
      assert.is_nil(obj._cfg)

      fake_hs.install({ existingFiles = { ["/opt/homebrew/bin/m1ddc"] = true } })
      obj = dofile("init.lua")
      obj:configure(validConfig({ backend = "m1ddc" }))
      assert.is_not_nil(obj._cfg)
    end)
  end)

  describe("start without a valid configuration", function()
    it("starts nothing", function()
      local hs, calls = fake_hs.install() -- no httpserver, bonjour, ...: touching them would raise
      local obj = dofile("init.lua")
      obj:configure(validConfig({ secret = "short" }))
      local before = #calls
      assert.are.equal(obj, obj:start())
      assert.is_nil(hs.httpserver)
      assert.is_nil(obj:status())
      local after = {}
      for i = before + 1, #calls do after[#after + 1] = calls[i].name end
      assert.are.same({ "log.e" }, after) -- only the log line, no second notification
    end)

    it("starts nothing before configure", function()
      fake_hs.install()
      local obj = dofile("init.lua")
      assert.are.equal(obj, obj:start())
      assert.is_nil(obj:status())
    end)
  end)

  describe("generateSecret", function()
    it("returns 64 hex characters", function()
      fake_hs.install()
      local obj = dofile("init.lua")
      local s = obj.generateSecret()
      assert.are.equal(64, #s)
      assert.is_truthy(s:match("^%x+$"))
    end)

    it("returns a different value each time", function()
      fake_hs.install()
      local obj = dofile("init.lua")
      assert.are_not.equal(obj.generateSecret(), obj.generateSecret())
    end)
  end)

  describe("bindHotkeys", function()
    it("passes claim and release actions with the user's mapping", function()
      local _, calls = fake_hs.install()
      local obj = dofile("init.lua")
      local mapping = { claim = { { "ctrl" }, "k" }, release = { { "ctrl" }, "j" } }
      assert.are.equal(obj, obj:bindHotkeys(mapping))
      assert.are.equal(1, count(calls, "bindHotkeysToSpec"))
      local spec, passed = calls[1].args[1], calls[1].args[2]
      assert.are.equal("function", type(spec.claim))
      assert.are.equal("function", type(spec.release))
      assert.are.equal(mapping, passed)
    end)

    it("hotkey actions are safe when the Spoon is not running", function()
      local _, calls = fake_hs.install()
      local obj = dofile("init.lua")
      obj:bindHotkeys({})
      local spec = calls[1].args[1]
      assert.has_no.errors(function()
        spec.claim()
        spec.release()
      end)
    end)
  end)

  describe("start with a valid configuration", function()
    local hs, calls, obj

    before_each(function()
      hs, calls = fake_hs.install({ full = true })
      obj = dofile("init.lua")
      obj:configure(validConfig())
    end)

    it("wires everything up and starts the node", function()
      assert.are.equal(0, #hs.httpserver.created)
      assert.are.equal(obj, obj:start())

      local server = hs.httpserver.created[1]
      assert.is_true(server.started)
      assert.are.equal(8765, server.port)

      local svc = hs.bonjour.published[1]
      assert.is_true(svc.published)
      assert.are.equal("desk-mini", svc.txt.node)
      assert.are.equal("1", svc.txt.v)
      assert.are.equal(8, #svc.txt.group)
      assert.is_true(hs.bonjour.browsers[1] ~= nil)

      assert.is_true(hs.caffeinate.watchers[1].started)
      assert.is_true(hs.timer.pending() >= 1) -- heartbeat

      local status = obj:status()
      assert.are.equal("desk-mini", status.node)
      assert.are.equal(16, #status.instance)
      assert.is_truthy(status.instance:match("^%x+$"))
      assert.is_not_nil(status.displays.main)
      assert.is_false(status.displays.main.visible)
    end)

    it("reports a port that cannot be listened on and keeps no half-started node", function()
      hs.httpserver.failStart = true
      assert.are.equal(obj, obj:start())
      assert.is_nil(obj._node)
      assert.is_nil(obj:status())
      assert.are.equal(0, #hs.bonjour.published)
      assert.is_nil(hs.caffeinate.watchers[1])
      local texts = {}
      for _, c in ipairs(calls) do
        if c.name == "notify.new" then texts[#texts + 1] = c.args[1].informativeText end
      end
      assert.are.same({ "DisplayKVM: cannot listen on port 8765" }, texts)
      assert.are.equal(1, count(calls, "log.e"))

      hs.httpserver.failStart = false
      obj:start()
      assert.is_not_nil(obj:status())
    end)

    it("signs messages with the instance reported by status()", function()
      local Message = dofile("message.lua")
      obj:start()
      local n = 0
      local peer = Message.new({
        secret = SECRET,
        node = "laptop",
        instance = "00000000deadbeef",
        hmac = function(k, d) return hs.hash.new("hmacSHA256", k):append(d):finish():value() end,
        now = function() return math.floor(hs.timer.secondsSinceEpoch() * 1000) end,
        random = function() n = n + 1 return string.format("%032x", n) end,
        codec = { encode = hs.json.encode, decode = hs.json.decode },
      })
      local raw, sig = peer:build("hello", {})
      local server = hs.httpserver.created[1]
      local body, status, headers = server.request("POST", "/v1/msg", { ["X-DisplayKVM-Sig"] = sig }, raw)
      assert.are.equal(200, status)
      local reply = peer:verify(body, headers["X-DisplayKVM-Sig"])
      assert.is_not_nil(reply)
      assert.are.equal("reply", reply.type)
      assert.are.equal("desk-mini", reply.from)
      assert.are.equal(obj:status().instance, reply.instance)
    end)

    it("rejects a message signed with another secret", function()
      local Message = dofile("message.lua")
      obj:start()
      local intruder = Message.new({
        secret = string.rep("cd", 32),
        node = "laptop",
        instance = "1",
        hmac = function(k, d) return hs.hash.new("hmacSHA256", k):append(d):finish():value() end,
        now = function() return math.floor(hs.timer.secondsSinceEpoch() * 1000) end,
        random = function() return "n" end,
        codec = { encode = hs.json.encode, decode = hs.json.decode },
      })
      local raw, sig = intruder:build("hello", {})
      local _, status = hs.httpserver.created[1].request("POST", "/v1/msg", { ["X-DisplayKVM-Sig"] = sig }, raw)
      assert.are.equal(401, status)
    end)

    describe("secret hygiene", function()
      local deepContains = dofile("spec/support/deep.lua")

      it("deepContains finds a value nested in tables, keys, metatables and substrings", function()
        local hidden = setmetatable({}, { __index = { deep = { "xx" .. SECRET .. "yy" } } })
        assert.is_true(deepContains({ a = { b = SECRET } }, SECRET))
        assert.is_true(deepContains({ [SECRET] = 1 }, SECRET))
        assert.is_true(deepContains({ hidden }, SECRET))
        local cyclic = {}
        cyclic.self = cyclic
        assert.is_false(deepContains(cyclic, SECRET))
      end)

      it("keeps the secret out of everything reachable from the Spoon object", function()
        obj:start()
        assert.is_false(deepContains(obj, SECRET))
        assert.is_false(deepContains(obj._node, SECRET))
        assert.is_false(deepContains(obj._cfg, SECRET))
      end)

      it("keeps it out after claim, release and when returned from them", function()
        obj:start()
        assert.is_false(deepContains(obj:claim(), SECRET))
        assert.is_false(deepContains(obj:release(), SECRET))
        assert.is_false(deepContains(obj:status(), SECRET))
      end)

      it("keeps it out when configured but not started", function()
        assert.is_false(deepContains(obj, SECRET))
      end)

      it("survives a restart: the secret is still found at start()", function()
        obj:start()
        obj:start()
        assert.is_false(deepContains(obj, SECRET))
        assert.is_true(hs.httpserver.created[2].started)
      end)

      it("never logs the secret", function()
        obj:configure(validConfig({ logLevel = "debug" }))
        obj:start()
        obj:claim()
        obj:release()
        obj:stop()
        assert.is_true(#obj._log.messages > 0)
        for _, entry in ipairs(obj._log.messages) do
          assert.is_nil(tostring(entry[2]):find(SECRET, 1, true))
        end
      end)
    end)

    it("publishes no Bonjour service when bonjour = false", function()
      obj:configure(validConfig({ bonjour = false }))
      obj:start()
      assert.are.equal(0, #hs.bonjour.published)
      assert.is_true(hs.httpserver.created[1].started)
    end)

    it("starts no lid sensor when activity.lid = false", function()
      obj:configure(validConfig({ activity = { lid = false } }))
      obj:start()
      assert.are.equal(0, #hs.task.created)
    end)

    it("stop() shuts the node down and status() becomes nil", function()
      obj:start()
      assert.are.equal(obj, obj:stop())
      assert.is_true(hs.httpserver.created[1].stopped)
      assert.is_true(hs.bonjour.published[1].stopped)
      assert.is_true(hs.caffeinate.watchers[1].stopped)
      assert.is_nil(obj:status())
      assert.has_no.errors(function() obj:stop() end)
    end)

    it("start() twice restarts with a fresh instance", function()
      obj:start()
      local first = obj:status().instance
      obj:start()
      assert.is_true(hs.httpserver.created[1].stopped)
      assert.is_true(hs.httpserver.created[2].started)
      assert.are_not.equal(first, obj:status().instance)
    end)

    it("claim() and release() reach the node", function()
      obj:start()
      assert.are.equal(obj, obj:claim("main"))
      assert.are.equal(obj, obj:claim())
      assert.are.equal(obj, obj:release())
      assert.are.equal(obj, obj:claim("nope"))
    end)

    it("claim() and release() are no-ops when stopped", function()
      assert.are.equal(obj, obj:claim())
      assert.are.equal(obj, obj:release())
      assert.is_nil(obj:status())
    end)
  end)
end)
