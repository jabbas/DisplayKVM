local json = require("dkjson")
local fakes = dofile("spec/support/fakes.lua")
local Message = dofile("message.lua")
local Transport = dofile("transport.lua")

describe("Transport", function()
  local clock, counter, desk, laptop, server, http, timer, discovery, logs, t
  local received, seen, replyStatus, replyBody

  local function hmac(k, d) return "H" .. #k .. ":" .. d end

  local function makeMessage(node, instance)
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
    })
  end

  local function makeLog()
    local l = { entries = {} }
    for _, level in ipairs({ "d", "i", "w", "e" }) do
      l[level] = function(msg) l.entries[#l.entries + 1] = { level = level, msg = msg } end
    end
    function l.count(level, pattern)
      local n = 0
      for _, e in ipairs(l.entries) do
        if e.level == level and (pattern == nil or e.msg:find(pattern, 1, true)) then n = n + 1 end
      end
      return n
    end
    return l
  end

  local function makeDiscovery()
    local d = { aliases = {}, peers = {}, namesList = {} }
    function d:resolve(name) return self.peers[name] end
    function d:names() return self.namesList end
    function d:alias(node, address) self.aliases[node] = address end
    return d
  end

  -- Signed envelope as a peer would send it to the server.
  local function incoming(from, type, body)
    local raw, sig = from:build(type, body)
    return raw, sig
  end

  local function post(raw, sig)
    return server.request("POST", "/v1/msg", { ["X-DisplayKVM-Sig"] = sig }, raw)
  end

  local function lastPost() return http.posts[#http.posts] end

  before_each(function()
    clock = 1000000
    counter = 0
    desk = makeMessage("desk-mini", "inst-desk")
    laptop = makeMessage("laptop", "inst-laptop")
    http = fakes.http()
    timer = fakes.timer()
    local httpserver = fakes.httpserver()
    discovery = makeDiscovery()
    discovery.peers["laptop"] = { host = "laptop.local.", port = 8765 }
    discovery.peers["192.0.2.5:8765"] = { host = "192.0.2.5", port = 8765 }
    logs = makeLog()
    received, seen = {}, {}
    replyStatus, replyBody = 204, nil
    t = Transport.new({
      httpserver = httpserver, http = http, timer = timer, message = desk, discovery = discovery,
      port = 8765, interface = "0.0.0.0", log = logs, now = function() return clock end,
    })
    t:start(function(msg)
      received[#received + 1] = msg
      return replyStatus, replyBody
    end, function(node) seen[#seen + 1] = node end)
    server = httpserver.created[1]
  end)

  describe("server", function()
    it("listens on the configured port and interface without ssl or bonjour", function()
      assert.is_false(server.ssl)
      assert.is_false(server.bonjour)
      assert.are.equal(8765, server.port)
      assert.are.equal("0.0.0.0", server.interface)
      assert.is_true(server.started)
    end)

    it("stops the server", function()
      t:stop()
      assert.is_true(server.stopped)
    end)

    it("limits the request body to 64 KiB", function()
      assert.are.equal(65536, server:maxBodySize())
    end)

    it("reports success from start()", function()
      t:stop()
      t = Transport.new({
        httpserver = fakes.httpserver(), http = http, timer = timer, message = desk, discovery = discovery,
        port = 8765, log = logs, now = function() return clock end,
      })
      assert.is_true(t:start(function() end))
    end)

    describe("when the server cannot listen", function()
      local httpserver, ok, err

      before_each(function()
        t:stop()
        httpserver = fakes.httpserver()
        httpserver.failStart = true
        logs = makeLog()
        t = Transport.new({
          httpserver = httpserver, http = http, timer = timer, message = desk, discovery = discovery,
          port = 8765, log = logs, now = function() return clock end,
        })
        ok, err = t:start(function() end)
      end)

      it("returns false with a reason naming the port", function()
        assert.is_false(ok)
        assert.matches("port 8765", err)
      end)

      it("logs an error and releases the server", function()
        assert.are.equal(1, logs.count("e", "8765"))
        assert.is_true(httpserver.created[1].stopped)
        assert.is_nil(t.server)
      end)
    end)

    it("answers 404 to a non-POST request", function()
      local body, status = server.request("GET", "/v1/msg", {}, "")
      assert.are.equal(404, status)
      assert.are.equal("", body)
    end)

    it("answers 404 to another path", function()
      local raw, sig = incoming(laptop, "state", {})
      local _, status = server.request("POST", "/other", { ["X-DisplayKVM-Sig"] = sig }, raw)
      assert.are.equal(404, status)
      assert.are.equal(0, #received)
    end)

    it("answers 401 with an empty body to a bad signature and does not call onMessage", function()
      local raw = incoming(laptop, "state", {})
      local body, status = post(raw, "forged")
      assert.are.equal(401, status)
      assert.are.equal("", body)
      assert.are.equal(0, #received)
    end)

    it("answers 401 when the signature header is missing", function()
      local raw = incoming(laptop, "state", {})
      local _, status = server.request("POST", "/v1/msg", {}, raw)
      assert.are.equal(401, status)
      assert.are.equal(0, #received)
    end)

    it("accepts the signature header in lower case", function()
      local raw, sig = incoming(laptop, "state", {})
      local _, status = server.request("POST", "/v1/msg", { ["x-displaykvm-sig"] = sig }, raw)
      assert.are.equal(204, status)
      assert.are.equal(1, #received)
    end)

    it("passes the verified message to onMessage and answers with its status", function()
      local raw, sig = incoming(laptop, "hello", { x = 1 })
      local body, status = post(raw, sig)
      assert.are.equal(204, status)
      assert.are.equal("", body)
      assert.are.equal("laptop", received[1].from)
      assert.are.equal("hello", received[1].type)
      assert.are.same({ x = 1 }, received[1].body)
    end)

    it("answers a replayed message with 401", function()
      local raw, sig = incoming(laptop, "state", {})
      post(raw, sig)
      local _, status = post(raw, sig)
      assert.are.equal(401, status)
      assert.are.equal(1, #received)
    end)

    it("wraps the reply body in a signed reply envelope", function()
      replyStatus, replyBody = 200, { state = {} }
      local raw, sig = incoming(laptop, "hello", {})
      local body, status, headers = post(raw, sig)
      assert.are.equal(200, status)
      assert.are.equal("application/json", headers["Content-Type"])
      local reply, reason = laptop:verify(body, headers["X-DisplayKVM-Sig"])
      assert.is_nil(reason)
      assert.are.equal("reply", reply.type)
      assert.are.equal("desk-mini", reply.from)
      assert.is_table(reply.body.state)
    end)

    it("answers 500 when onMessage raises", function()
      t:stop()
      local httpserver = fakes.httpserver()
      t = Transport.new({
        httpserver = httpserver, http = http, timer = timer, message = desk, discovery = discovery,
        port = 8765, log = logs, now = function() return clock end,
      })
      t:start(function() error("boom") end)
      local raw, sig = incoming(laptop, "state", {})
      local _, status = httpserver.created[1].request("POST", "/v1/msg", { ["X-DisplayKVM-Sig"] = sig }, raw)
      assert.are.equal(500, status)
      assert.are.equal(1, logs.count("e"))
    end)

    describe("rejection logging", function()
      local function stalePost()
        local raw, sig = incoming(laptop, "state", {})
        clock = clock + 31000
        return post(raw, sig)
      end

      it("warns about clock skew with the sender of a stale message", function()
        local _, status = stalePost()
        assert.are.equal(401, status)
        assert.are.equal(1, logs.count("w", "clock skew with laptop"))
      end)

      it("logs a stale rejection at most once per 60 s", function()
        stalePost()
        stalePost()
        assert.are.equal(1, logs.count("w", "clock skew"))
        clock = clock + 60000
        stalePost()
        assert.are.equal(2, logs.count("w", "clock skew"))
      end)

      it("logs other reasons at debug level, rate limited per reason", function()
        local raw = incoming(laptop, "state", {})
        post(raw, "forged")
        post(raw, "forged")
        assert.are.equal(1, logs.count("d", "bad-signature"))
        local good, sig = incoming(laptop, "state", {})
        post(good, sig)
        post(good, sig)
        post(good, sig)
        assert.are.equal(1, logs.count("d", "replay"))
        assert.are.equal(1, logs.count("d", "bad-signature"))
        assert.are.equal(0, logs.count("w"))
      end)
    end)
  end)

  describe("send", function()
    local function reply(body, from)
      return (from or laptop):build("reply", body)
    end

    local function result()
      local r = { calls = 0 }
      r.cb = function(ok, replyTable, status)
        r.calls = r.calls + 1
        r.ok, r.reply, r.status = ok, replyTable, status
      end
      return r
    end

    it("posts a signed envelope to the resolved address", function()
      t:send("laptop", "state", { x = 1 }, function() end)
      local p = lastPost()
      assert.are.equal("http://laptop.local.:8765/v1/msg", p.url)
      assert.are.equal("application/json", p.headers["Content-Type"])
      local msg, reason = laptop:verify(p.data, p.headers["X-DisplayKVM-Sig"])
      assert.is_nil(reason)
      assert.are.equal("state", msg.type)
      assert.are.equal("desk-mini", msg.from)
      assert.are.same({ x = 1 }, msg.body)
    end)

    it("fails with unknown-peer without posting", function()
      local r = result()
      t:send("studio", "state", {}, r.cb)
      assert.is_false(r.ok)
      assert.are.equal("unknown-peer", r.status)
      assert.are.equal(1, r.calls)
      assert.are.equal(0, #http.posts)
    end)

    it("returns the verified reply body and reports the sender as seen", function()
      local r = result()
      t:send("laptop", "hello", {}, r.cb)
      local raw, sig = reply({ result = "ok" })
      http.deliver(200, raw, { ["X-DisplayKVM-Sig"] = sig })
      assert.is_true(r.ok)
      assert.are.same({ result = "ok" }, r.reply)
      assert.are.equal(200, r.status)
      assert.are.same({ "laptop" }, seen)
      assert.are.equal(1, r.calls)
    end)

    it("finds the reply signature header case-insensitively", function()
      local r = result()
      t:send("laptop", "hello", {}, r.cb)
      local raw, sig = reply({ result = "ok" })
      http.deliver(200, raw, { ["x-displaykvm-sig"] = sig })
      assert.is_true(r.ok)
    end)

    it("treats 204 as success without a reply", function()
      local r = result()
      t:send("laptop", "state", {}, r.cb)
      http.deliver(204, "", {})
      assert.is_true(r.ok)
      assert.is_nil(r.reply)
      assert.are.equal(204, r.status)
      assert.are.same({}, seen)
    end)

    it("reports bad-reply for a reply with a bad signature", function()
      local r = result()
      t:send("laptop", "hello", {}, r.cb)
      local raw = reply({ result = "ok" })
      http.deliver(200, raw, { ["X-DisplayKVM-Sig"] = "forged" })
      assert.is_false(r.ok)
      assert.are.equal("bad-reply", r.status)
      assert.are.same({}, seen)
    end)

    it("reports bad-reply for a 200 without a body", function()
      local r = result()
      t:send("laptop", "hello", {}, r.cb)
      http.deliver(200, "", {})
      assert.are.equal("bad-reply", r.status)
    end)

    it("reports bad-reply when the envelope is not a reply", function()
      local r = result()
      t:send("laptop", "hello", {}, r.cb)
      local raw, sig = laptop:build("state", {})
      http.deliver(200, raw, { ["X-DisplayKVM-Sig"] = sig })
      assert.are.equal("bad-reply", r.status)
      assert.are.same({}, seen)
    end)

    it("warns on 401 and mentions the secret and clock", function()
      local r = result()
      t:send("laptop", "state", {}, r.cb)
      http.deliver(401, "", {})
      assert.is_false(r.ok)
      assert.are.equal(401, r.status)
      assert.are.equal(1, logs.count("w", "401 from laptop (check shared secret and NTP clock sync)"))
    end)

    it("passes other statuses through", function()
      local r = result()
      t:send("laptop", "state", {}, r.cb)
      http.deliver(503, "", {})
      assert.is_false(r.ok)
      assert.are.equal(503, r.status)
    end)

    it("passes a transport failure status through", function()
      local r = result()
      t:send("laptop", "state", {}, r.cb)
      http.deliver(-1, "connection refused", {})
      assert.is_false(r.ok)
      assert.are.equal(-1, r.status)
    end)

    it("times out after the soft limit", function()
      local r = result()
      t:send("laptop", "state", {}, r.cb)
      timer.advance(4.9)
      assert.are.equal(0, r.calls)
      timer.advance(0.2)
      assert.is_false(r.ok)
      assert.are.equal("timeout", r.status)
      assert.are.equal(1, r.calls)
    end)

    it("honours a custom soft timeout", function()
      local httpserver = fakes.httpserver()
      t = Transport.new({
        httpserver = httpserver, http = http, timer = timer, message = desk, discovery = discovery,
        port = 8765, log = logs, now = function() return clock end, softTimeout = 2,
      })
      t:start(function() end)
      local r = result()
      t:send("laptop", "state", {}, r.cb)
      timer.advance(2)
      assert.are.equal("timeout", r.status)
    end)

    it("does not call cb a second time when a reply arrives after the timeout", function()
      local r = result()
      t:send("laptop", "hello", {}, r.cb)
      timer.advance(5)
      assert.are.equal("timeout", r.status)
      local raw, sig = reply({ result = "ok" })
      http.deliver(200, raw, { ["X-DisplayKVM-Sig"] = sig })
      http.deliver(204, "", {})
      assert.are.equal(1, r.calls)
      assert.are.equal("timeout", r.status)
      assert.is_false(r.ok)
    end)

    it("cancels the soft timeout once the response arrived", function()
      local r = result()
      t:send("laptop", "state", {}, r.cb)
      http.deliver(204, "", {})
      assert.are.equal(0, timer.pending())
      timer.advance(10)
      assert.are.equal(1, r.calls)
      assert.is_true(r.ok)
    end)

    it("does not call cb twice when the response is delivered twice", function()
      local r = result()
      t:send("laptop", "state", {}, r.cb)
      http.deliver(204, "", {})
      http.deliver(204, "", {})
      assert.are.equal(1, r.calls)
    end)

    it("aliases the node name to a static address after a verified reply", function()
      local r = result()
      t:send("192.0.2.5:8765", "hello", {}, r.cb)
      local raw, sig = reply({ result = "ok" })
      http.deliver(200, raw, { ["X-DisplayKVM-Sig"] = sig })
      assert.are.equal("192.0.2.5:8765", discovery.aliases["laptop"])
      assert.are.same({ "laptop" }, seen)
    end)

    it("does not alias a Bonjour peer", function()
      local r = result()
      t:send("laptop", "hello", {}, r.cb)
      local raw, sig = reply({ result = "ok" })
      http.deliver(200, raw, { ["X-DisplayKVM-Sig"] = sig })
      assert.is_nil(discovery.aliases["laptop"])
    end)

    it("does not alias after a bad reply", function()
      local r = result()
      t:send("192.0.2.5:8765", "hello", {}, r.cb)
      http.deliver(200, "junk", { ["X-DisplayKVM-Sig"] = "forged" })
      assert.is_nil(discovery.aliases["laptop"])
    end)

    it("works when onSeen was not provided", function()
      t:start(function() end)
      local r = result()
      t:send("laptop", "hello", {}, r.cb)
      local raw, sig = reply({ result = "ok" })
      http.deliver(200, raw, { ["X-DisplayKVM-Sig"] = sig })
      assert.is_true(r.ok)
    end)
  end)

  describe("sendSync", function()
    it("returns true on 204 and sends a signed POST", function()
      assert.is_true(t:sendSync("laptop", "state", { x = 1 }, 1))
      local call = http.requests[1]
      assert.are.equal("http://laptop.local.:8765/v1/msg", call.url)
      assert.are.equal("POST", call.method)
      assert.are.equal("application/json", call.headers["Content-Type"])
      local msg = laptop:verify(call.data, call.headers["X-DisplayKVM-Sig"])
      assert.are.equal("state", msg.type)
    end)

    it("returns false when doRequest raises", function()
      http.sync = function() error("network down") end
      assert.is_false(t:sendSync("laptop", "state", {}, 1))
    end)

    it("returns false on an error status", function()
      http.sync = function() return 401, "", {} end
      assert.is_false(t:sendSync("laptop", "state", {}, 1))
      http.sync = function() return -1, "refused", {} end
      assert.is_false(t:sendSync("laptop", "state", {}, 1))
    end)

    it("returns false for an unknown peer without a request", function()
      assert.is_false(t:sendSync("studio", "state", {}, 1))
      assert.are.equal(0, #http.requests)
    end)
  end)

  describe("broadcastSync", function()
    it("sends to every known peer in order and survives failures", function()
      discovery.namesList = { "192.0.2.5:8765", "laptop" }
      http.sync = function(call)
        if call.url:find("192.0.2.5", 1, true) then error("unreachable") end
        return 204, "", {}
      end
      local okCount = t:broadcastSync("state", { x = 1 }, 1)
      assert.are.equal(2, #http.requests)
      assert.are.equal("http://192.0.2.5:8765/v1/msg", http.requests[1].url)
      assert.are.equal("http://laptop.local.:8765/v1/msg", http.requests[2].url)
      assert.are.equal(1, okCount)
    end)

    it("does nothing without peers", function()
      assert.are.equal(0, t:broadcastSync("state", {}, 1))
      assert.are.equal(0, #http.requests)
    end)
  end)
end)
