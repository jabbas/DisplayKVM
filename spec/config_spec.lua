local Config = dofile("config.lua")

describe("Config", function()
  local env, raw

  local function deep(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deep(v) end
    return c
  end

  local function with(mut)
    local r = deep(raw)
    mut(r)
    return r
  end

  local function fails(r, substring)
    local cfg, err = Config.validate(r, env)
    assert.is_nil(cfg)
    assert.is_string(err)
    assert.is_truthy(err:find("^DisplayKVM: "), err)
    assert.is_truthy(err:find(substring, 1, true), err)
  end

  before_each(function()
    env = {
      hostname = "laptop",
      fileExists = function() return true end,
      builtinBackends = {
        m1ddc = { defaultPath = "/opt/homebrew/bin/m1ddc" },
        ddcctl = { defaultPath = "/opt/homebrew/bin/ddcctl" },
      },
    }
    raw = {
      secret = string.rep("a", 64),
      displays = {
        left = { match = "DELL", inputs = { ["desk-mini"] = 15, laptop = 16 } },
      },
    }
  end)

  describe("defaults", function()
    it("normalises a minimal config", function()
      local cfg, err = Config.validate(raw, env)
      assert.is_nil(err)
      assert.are.equal("laptop", cfg.node)
      assert.are.equal(string.rep("a", 64), cfg.secret)
      assert.are.equal("m1ddc", cfg.backend)
      assert.are.same({}, cfg.backendOptions)
      assert.are.equal(8765, cfg.port)
      assert.are.same({}, cfg.peers)
      assert.is_true(cfg.bonjour)
      assert.is_nil(cfg.interface)
      assert.are.same({ userIdle = 5, startIdle = 30, lid = true }, cfg.activity)
      assert.are.equal(30, cfg.heartbeat)
      assert.are.equal("info", cfg.logLevel)
      assert.are.same({
        left = { match = "DELL", inputs = { ["desk-mini"] = 15, laptop = 16 }, home = "desk-mini", pull = true },
      }, cfg.displays)
    end)

    it("takes node from raw when given", function()
      local cfg = Config.validate(with(function(r) r.node = "desk-mini" end), env)
      assert.are.equal("desk-mini", cfg.node)
    end)

    it("defaults home to the alphabetically first node", function()
      local cfg = Config.validate(with(function(r)
        r.displays.left.inputs = { zeta = 1, alpha = 2, laptop = 3 }
      end), env)
      assert.are.equal("alpha", cfg.displays.left.home)
    end)

    it("keeps explicit home and pull = false", function()
      local cfg = Config.validate(with(function(r)
        r.displays.left.home = "laptop"
        r.displays.left.pull = false
      end), env)
      assert.are.equal("laptop", cfg.displays.left.home)
      assert.is_false(cfg.displays.left.pull)
    end)

    it("merges partial activity with defaults", function()
      local cfg = Config.validate(with(function(r) r.activity = { lid = false } end), env)
      assert.are.same({ userIdle = 5, startIdle = 30, lid = false }, cfg.activity)
    end)

    it("accepts explicit overrides", function()
      local cfg, err = Config.validate(with(function(r)
        r.port = 9000
        r.bonjour = false
        r.interface = "en0"
        r.heartbeat = 10
        r.logLevel = "debug"
        r.peers = { "192.0.2.10:8765", "studio.local:9000" }
        r.activity = { userIdle = 2, startIdle = 60 }
        r.backendOptions = { inputAlt = true }
      end), env)
      assert.is_nil(err)
      assert.are.equal(9000, cfg.port)
      assert.is_false(cfg.bonjour)
      assert.are.equal("en0", cfg.interface)
      assert.are.equal(10, cfg.heartbeat)
      assert.are.equal("debug", cfg.logLevel)
      assert.are.same({ "192.0.2.10:8765", "studio.local:9000" }, cfg.peers)
      assert.are.same({ userIdle = 2, startIdle = 60, lid = true }, cfg.activity)
      assert.are.same({ inputAlt = true }, cfg.backendOptions)
    end)

    it("does not mutate the raw table", function()
      local before = deep(raw)
      Config.validate(raw, env)
      assert.are.same(before, raw)
    end)
  end)

  describe("secret", function()
    it("is required", function()
      fails(with(function(r) r.secret = nil end), "secret")
    end)
    it("must be hex", function()
      fails(with(function(r) r.secret = string.rep("z", 64) end), "secret")
    end)
    it("must be at least 64 chars", function()
      fails(with(function(r) r.secret = string.rep("a", 63) end), "secret")
    end)
    it("accepts longer and mixed-case hex", function()
      local cfg = Config.validate(with(function(r) r.secret = string.rep("aB3", 30) end), env)
      assert.is_table(cfg)
    end)
  end)

  describe("displays", function()
    it("are required", function()
      fails(with(function(r) r.displays = nil end), "displays")
    end)
    it("must not be empty", function()
      fails(with(function(r) r.displays = {} end), "displays")
    end)

    it("rejects the array form (display ids must be strings)", function()
      fails(with(function(r) r.displays = { r.displays.left } end), "displays")
    end)

    it("rejects mixed keys without crashing", function()
      fails(with(function(r) r.displays[1] = r.displays.left end), "displays")
    end)

    it("rejects an empty display id", function()
      fails(with(function(r) r.displays[""] = r.displays.left end), "displays")
    end)
    it("need inputs", function()
      fails(with(function(r) r.displays.left.inputs = nil end), "inputs")
    end)
    it("need non-empty inputs", function()
      fails(with(function(r) r.displays.left.inputs = {} end), "inputs")
    end)
    it("need integer input values", function()
      fails(with(function(r) r.displays.left.inputs.laptop = "HDMI" end), "inputs")
      fails(with(function(r) r.displays.left.inputs.laptop = 16.5 end), "inputs")
    end)
    it("need match", function()
      fails(with(function(r) r.displays.left.match = nil end), "match")
    end)
    it("reject an empty match string", function()
      fails(with(function(r) r.displays.left.match = "" end), "match")
    end)
    it("reject a match of the wrong type", function()
      fails(with(function(r) r.displays.left.match = 5 end), "match")
    end)
    it("accept a per-node match table", function()
      local m = { ["desk-mini"] = "UUID-1", laptop = "UUID-2" }
      local cfg = Config.validate(with(function(r) r.displays.left.match = m end), env)
      assert.are.same(m, cfg.displays.left.match)
    end)
    it("reject a match table with a non-string or empty value", function()
      fails(with(function(r) r.displays.left.match = { ["desk-mini"] = "A", laptop = 3 } end), "match")
      fails(with(function(r) r.displays.left.match = { ["desk-mini"] = "A", laptop = "" } end), "match")
    end)
    it("reject a match table missing a node from inputs", function()
      fails(with(function(r) r.displays.left.match = { ["desk-mini"] = "A" } end), "match")
    end)
    it("reject home without an input", function()
      fails(with(function(r) r.displays.left.home = "studio" end), "home")
    end)
    it("reject a non-boolean pull", function()
      fails(with(function(r) r.displays.left.pull = "yes" end), "pull")
    end)
  end)

  describe("node", function()
    it("must appear in some inputs", function()
      fails(with(function(r) r.node = "studio" end), "node")
    end)
    it("falls back to hostname which must appear in inputs", function()
      env.hostname = "studio"
      fails(raw, "node")
    end)
    it("may appear in only one of several displays", function()
      local cfg = Config.validate(with(function(r)
        r.node = "studio"
        r.displays.right = { match = "LG", inputs = { studio = 1, ["desk-mini"] = 2 } }
      end), env)
      assert.is_table(cfg)
    end)
  end)

  describe("backend", function()
    it("rejects an unknown name", function()
      fails(with(function(r) r.backend = "nope" end), "backend")
    end)
    it("rejects a missing default binary", function()
      env.fileExists = function() return false end
      fails(raw, "backend")
    end)
    it("checks the default path of the named backend", function()
      local seen
      env.fileExists = function(p) seen = p; return true end
      Config.validate(with(function(r) r.backend = "ddcctl" end), env)
      assert.are.equal("/opt/homebrew/bin/ddcctl", seen)
    end)
    it("prefers backendOptions.path", function()
      local seen
      env.fileExists = function(p) seen = p; return true end
      Config.validate(with(function(r) r.backendOptions = { path = "/custom/m1ddc" } end), env)
      assert.are.equal("/custom/m1ddc", seen)
    end)
    it("rejects a missing custom path", function()
      env.fileExists = function(p) return p ~= "/custom/m1ddc" end
      fails(with(function(r) r.backendOptions = { path = "/custom/m1ddc" } end), "backend")
    end)
    it("rejects a backend of the wrong type", function()
      fails(with(function(r) r.backend = 42 end), "backend")
    end)
    it("accepts a function without checking files", function()
      local called = false
      env.fileExists = function() called = true; return false end
      local fn = function() end
      local r = deep(raw)
      r.backend = fn
      local cfg, err = Config.validate(r, env)
      assert.is_nil(err)
      assert.are.equal(fn, cfg.backend)
      assert.is_false(called)
    end)
  end)

  describe("peers", function()
    it("must be a list", function()
      fails(with(function(r) r.peers = "192.0.2.10:8765" end), "peers")
    end)
    for _, bad in ipairs({ "nohost", "host:", ":8765", "host:abc", "host:0", "host:70000", "a b:80", 5 }) do
      it("rejects entry " .. tostring(bad), function()
        fails(with(function(r) r.peers = { bad } end), "peers")
      end)
    end
  end)

  describe("scalars", function()
    it("reject heartbeat <= 0", function()
      fails(with(function(r) r.heartbeat = 0 end), "heartbeat")
      fails(with(function(r) r.heartbeat = -5 end), "heartbeat")
    end)
    it("reject a non-numeric heartbeat", function()
      fails(with(function(r) r.heartbeat = "30" end), "heartbeat")
    end)
    it("reject a bad port", function()
      for _, p in ipairs({ 0, 65536, 80.5, "8765" }) do
        fails(with(function(r) r.port = p end), "port")
      end
    end)
    it("reject a non-boolean bonjour", function()
      fails(with(function(r) r.bonjour = "no" end), "bonjour")
    end)
    it("reject a non-string logLevel", function()
      fails(with(function(r) r.logLevel = 3 end), "logLevel")
    end)
    it("reject a non-string interface", function()
      fails(with(function(r) r.interface = 0 end), "interface")
    end)
    it("reject bad activity values", function()
      fails(with(function(r) r.activity = { userIdle = "5" } end), "activity")
      fails(with(function(r) r.activity = { startIdle = true } end), "activity")
      fails(with(function(r) r.activity = { lid = "yes" } end), "activity")
      fails(with(function(r) r.activity = "none" end), "activity")
    end)
    it("reject a non-table raw config", function()
      local cfg, err = Config.validate(nil, env)
      assert.is_nil(cfg)
      assert.is_truthy(err:find("^DisplayKVM: "))
    end)
  end)
end)
