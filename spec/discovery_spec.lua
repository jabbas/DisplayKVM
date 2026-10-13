local fakes = dofile("spec/support/fakes.lua")
local Discovery = dofile("discovery.lua")

describe("Discovery", function()
  local bonjour, d, up, down

  local function remote(name, node, opts)
    opts = opts or {}
    return bonjour.remote({
      name = name,
      host = opts.host or (node or "x") .. ".local.",
      port = opts.port or 8765,
      txt = opts.txt or { v = "1", group = "abcd1234", node = node },
      result = opts.result == nil and "resolved" or opts.result,
      err = opts.err,
    })
  end

  local function make(extra)
    local cfg = { bonjour = bonjour, node = "desk-mini", port = 8765, groupId = "abcd1234", staticPeers = {} }
    for k, v in pairs(extra or {}) do cfg[k] = v end
    return Discovery.new(cfg)
  end

  before_each(function()
    bonjour = fakes.bonjour()
    up, down = {}, {}
    d = make()
  end)

  local function start()
    d:start(function(n) up[#up + 1] = n end, function(n) down[#down + 1] = n end)
  end

  describe("publishing and browsing", function()
    it("publishes the service with the group TXT record", function()
      start()
      local svc = bonjour.published[1]
      assert.are.equal("desk-mini", svc.name)
      assert.are.equal("_displaykvm._tcp.", svc.serviceType)
      assert.are.equal(8765, svc.port)
      assert.are.same({ v = "1", group = "abcd1234", node = "desk-mini" }, svc.txt)
      assert.is_true(svc.published)
    end)

    it("browses for the service type in the local domain", function()
      start()
      local b = bonjour.browsers[1]
      assert.are.equal("_displaykvm._tcp.", b.serviceType)
      assert.are.equal("local.", b.domain)
    end)

    it("does not touch Bonjour when disabled", function()
      d = make({ enabled = false, staticPeers = { "192.0.2.5:8765" } })
      start()
      assert.are.equal(0, #bonjour.browsers)
      assert.are.equal(0, #bonjour.published)
      assert.are.same({ "192.0.2.5:8765" }, up)
    end)

    it("stops the browser and the published service", function()
      start()
      d:stop()
      assert.is_true(bonjour.browsers[1].stopped)
      assert.is_true(bonjour.published[1].stopped)
    end)
  end)

  describe("bonjour peers", function()
    before_each(start)

    it("resolves with a 5 s timeout and reports the peer up", function()
      local svc = remote("laptop", "laptop", { host = "laptop.local.", port = 9000 })
      bonjour.browsers[1].add(svc)
      assert.are.equal(5, svc.timeout)
      assert.are.same({ "laptop" }, up)
      assert.are.same({ host = "laptop.local.", port = 9000 }, d:resolve("laptop"))
      assert.are.same({ "laptop" }, d:names())
    end)

    it("names the peer after txt.node, not the service name", function()
      bonjour.browsers[1].add(remote("laptop (2)", "laptop"))
      assert.are.same({ "laptop" }, up)
      assert.is_not_nil(d:resolve("laptop"))
      assert.is_nil(d:resolve("laptop (2)"))
    end)

    it("skips a service from another group", function()
      local txt = { v = "1", group = "ffffffff", node = "intruder" }
      bonjour.browsers[1].add(remote("intruder", "intruder", { txt = txt }))
      assert.are.same({}, up)
      assert.is_nil(d:resolve("intruder"))
    end)

    it("skips a service with another protocol version", function()
      local txt = { v = "2", group = "abcd1234", node = "laptop" }
      bonjour.browsers[1].add(remote("laptop", "laptop", { txt = txt }))
      assert.are.same({}, up)
    end)

    it("skips a service without txt.node", function()
      local txt = { v = "1", group = "abcd1234" }
      bonjour.browsers[1].add(remote("laptop", nil, { txt = txt }))
      assert.are.same({}, up)
    end)

    it("skips our own service", function()
      bonjour.browsers[1].add(remote("desk-mini (2)", "desk-mini"))
      assert.are.same({}, up)
      assert.are.same({}, d:names())
    end)

    it("skips entries whose resolution fails or times out", function()
      bonjour.browsers[1].add(remote("a", "a", { result = "error", err = "timeout" }))
      bonjour.browsers[1].add(remote("b", "b", { result = "stop" }))
      assert.are.same({}, up)
      assert.are.same({}, d:names())
    end)

    it("logs a failed resolution at debug level", function()
      local entries = {}
      d = make({ log = { d = function(m) entries[#entries + 1] = m end } })
      start()
      bonjour.browsers[2].add(remote("a", "a", { result = "error", err = "timeout" }))
      assert.are.equal(1, #entries)
      assert.is_truthy(entries[1]:find("timeout", 1, true))
    end)

    it("accepts a peer whose resolution completes later", function()
      local svc = remote("laptop", "laptop", { result = false })
      bonjour.browsers[1].add(svc)
      assert.are.same({}, up)
      svc.complete("resolved")
      assert.are.same({ "laptop" }, up)
    end)

    it("reports onDown after the service is removed", function()
      local svc = remote("laptop", "laptop")
      bonjour.browsers[1].add(svc)
      bonjour.browsers[1].remove(svc)
      assert.are.same({ "laptop" }, down)
      assert.is_nil(d:resolve("laptop"))
      assert.are.same({}, d:names())
    end)

    it("stays up while another service of the same node remains", function()
      local a, b = remote("laptop", "laptop"), remote("laptop (2)", "laptop")
      bonjour.browsers[1].add(a)
      bonjour.browsers[1].add(b)
      assert.are.same({ "laptop" }, up)
      bonjour.browsers[1].remove(a)
      assert.are.same({}, down)
      bonjour.browsers[1].remove(b)
      assert.are.same({ "laptop" }, down)
    end)

    it("ignores the removal of an unknown service", function()
      bonjour.browsers[1].remove(remote("ghost", "ghost"))
      assert.are.same({}, down)
    end)
  end)

  describe("static peers", function()
    before_each(function()
      d = make({ staticPeers = { "192.0.2.5:8765", "192.0.2.6:9000" } })
      start()
    end)

    it("reports them up immediately, named by address", function()
      assert.are.same({ "192.0.2.5:8765", "192.0.2.6:9000" }, up)
      assert.are.same({ "192.0.2.5:8765", "192.0.2.6:9000" }, d:names())
    end)

    it("resolves the address", function()
      assert.are.same({ host = "192.0.2.6", port = 9000 }, d:resolve("192.0.2.6:9000"))
    end)

    it("resolves a node name through its alias", function()
      assert.is_nil(d:resolve("laptop"))
      d:alias("laptop", "192.0.2.5:8765")
      assert.are.same({ host = "192.0.2.5", port = 8765 }, d:resolve("laptop"))
    end)

    it("prefers a Bonjour entry over an alias", function()
      d:alias("laptop", "192.0.2.5:8765")
      bonjour.browsers[1].add(remote("laptop", "laptop", { host = "laptop.local." }))
      assert.are.equal("laptop.local.", d:resolve("laptop").host)
    end)

    it("does not list a static address twice once its node is found via Bonjour", function()
      d:alias("laptop", "192.0.2.5:8765")
      bonjour.browsers[1].add(remote("laptop", "laptop"))
      assert.are.same({ "192.0.2.6:9000", "laptop" }, d:names())
    end)

    it("ignores an alias to an unknown address", function()
      d:alias("laptop", "192.0.2.99:1")
      assert.is_nil(d:resolve("laptop"))
    end)
  end)
end)
