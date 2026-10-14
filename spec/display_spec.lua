local fakes = dofile("spec/support/fakes.lua")
local Runner = dofile("runner.lua")
local Display = dofile("display.lua")

local UUID_A = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
local UUID_B = "1B2C3D4E-0000-1111-2222-333344445555"

describe("Display", function()
  local timer, task, runner, screens, backend, opts, results, logger

  -- Fake tasks complete on the next timer tick (latency 0) unless a latency is given.
  local function build(spec, script, latency)
    timer = fakes.timer()
    task = fakes.task(script or {}, { timer = timer, latency = latency or 0 })
    runner = Runner.new({
      task = task,
      timer = timer,
      usleep = function(us) timer.advance(us / 1000000) end,
      clock = timer.now,
    })
    return Display.new("main", spec, "desk-mini", {
      screens = function() return screens end,
      backend = backend,
      backendOptions = opts,
      runner = runner,
      timer = timer,
      log = logger,
    })
  end

  local function record()
    results = {}
    return function(ok, reason) results[#results + 1] = { ok, reason } end
  end

  before_each(function()
    screens = { { uuid = UUID_A, name = "DELL U2720Q (2)" }, { uuid = UUID_B, name = "LG-27" } }
    backend = dofile("backends/m1ddc.lua")
    opts = {}
    logger = nil
  end)

  local function spec(match)
    return { match = match, inputs = { ["desk-mini"] = 15, laptop = 16 }, home = "desk-mini", pull = true }
  end

  it("exposes id, pull, home and per-node inputs", function()
    local d = build(spec(UUID_A))
    assert.equals("main", d.id)
    assert.is_true(d.pull)
    assert.equals("desk-mini", d.home)
    assert.equals(15, d:inputFor("desk-mini"))
    assert.equals(16, d:inputFor("laptop"))
    assert.is_nil(d:inputFor("nobody"))
  end)

  describe("target / visible", function()
    it("matches a UUID by equality", function()
      local d = build(spec(UUID_B))
      assert.same({ uuid = UUID_B, name = "LG-27" }, d:target())
      assert.is_true(d:visible())
    end)

    it("matches a UUID case-insensitively", function()
      local d = build(spec(UUID_B:lower()))
      assert.equals(UUID_B, d:target().uuid)
    end)

    it("does not treat a UUID-shaped match as a name substring", function()
      screens = { { uuid = UUID_A, name = "prefix " .. UUID_B } }
      local d = build(spec(UUID_B))
      assert.is_nil(d:target())
      assert.is_false(d:visible())
    end)

    it("matches a name with Lua pattern characters as a plain substring", function()
      local d = build(spec("U2720Q (2)"))
      assert.equals(UUID_A, d:target().uuid)
      d = build(spec("LG-27"))
      assert.equals(UUID_B, d:target().uuid)
    end)

    it("does not interpret pattern magic characters", function()
      screens = { { uuid = UUID_A, name = "DELL U2720Q 2" } }
      assert.is_nil(build(spec("U2720Q (2)")):target())
      screens = { { uuid = UUID_A, name = "LGG27" } }
      assert.is_nil(build(spec("LG-27")):target())
      screens = { { uuid = UUID_A, name = "anything" } }
      assert.is_nil(build(spec(".*")):target())
    end)

    it("uses the per-node entry of a table match", function()
      local d = build(spec({ ["desk-mini"] = "LG-27", laptop = UUID_A }))
      assert.equals(UUID_B, d:target().uuid)
    end)

    it("is invisible when a table match has no entry for this node", function()
      local d = build(spec({ laptop = UUID_A }))
      assert.is_nil(d:target())
      assert.is_false(d:visible())
    end)

    it("is invisible when no screen matches", function()
      screens = {}
      assert.is_false(build(spec(UUID_A)):visible())
    end)
  end)

  describe("switchTo with a backend table", function()
    it("reports not-visible without running anything", function()
      screens = {}
      local d = build(spec(UUID_A))
      d:switchTo("laptop", record())
      assert.same({ { false, "not-visible" } }, results)
      assert.equals(0, #task.created)
    end)

    it("runs the backend with the node's input", function()
      local d = build(spec(UUID_A), { { 0, "", "" } })
      d:switchTo("laptop", record())
      assert.equals("/opt/homebrew/bin/m1ddc", task.created[1].path)
      assert.same({ "display", UUID_A, "set", "input", "16" }, task.created[1].args)
      timer.advance(0)
      assert.same({ { true } }, results)
    end)

    it("prefers backendOptions.path over the default path", function()
      opts = { path = "/usr/local/bin/m1ddc" }
      local d = build(spec(UUID_A), { { 0, "", "" } })
      d:switchTo("laptop", record())
      assert.equals("/usr/local/bin/m1ddc", task.created[1].path)
    end)

    it("passes backendOptions to the backend", function()
      opts = { index = 3 }
      backend = dofile("backends/ddcctl.lua")
      local d = build(spec(UUID_A), { { 0, "", "" } })
      d:switchTo("laptop", record())
      assert.same({ "-d", "3", "-i", "16" }, task.created[1].args)
    end)

    it("retries once after 1 s when the first attempt fails", function()
      local d = build(spec(UUID_A), { { 1, "", "err" }, { 0, "", "" } })
      d:switchTo("laptop", record())
      timer.advance(0)
      assert.same({}, results)
      timer.advance(0.9)
      assert.equals(1, #task.created)
      timer.advance(0.1)
      assert.equals(2, #task.created)
      timer.advance(0)
      assert.same({ { true } }, results)
    end)

    it("reports backend-error after two failures", function()
      local d = build(spec(UUID_A), { { 1, "", "err" }, { 1, "", "err" } })
      d:switchTo("laptop", record())
      timer.advance(0)
      timer.advance(1)
      timer.advance(10)
      assert.same({ { false, "backend-error" } }, results)
      assert.equals(2, #task.created)
    end)

    it("treats backend timeouts as failures", function()
      local d = build(spec(UUID_A), { { 0, "", "" }, { 0, "", "" } }, 100)
      d:switchTo("laptop", record())
      timer.advance(5)
      assert.same({}, results)
      assert.equals(1, #task.created)
      timer.advance(1)
      assert.equals(2, #task.created)
      timer.advance(5)
      assert.same({ { false, "backend-error" } }, results)
    end)

    it("reports an unknown node", function()
      local d = build(spec(UUID_A))
      d:switchTo("nobody", record())
      assert.same({ { false, "unknown-node" } }, results)
      assert.equals(0, #task.created)
    end)
  end)

  describe("switchTo with a backend function", function()
    it("passes {id, uuid, name} and the node's input", function()
      local seen
      backend = function(target, input, done) seen = { target, input } done(true) end
      local d = build(spec(UUID_B))
      d:switchTo("laptop", record())
      assert.same({ { id = "main", uuid = UUID_B, name = "LG-27" }, 16 }, seen)
      assert.same({ { true } }, results)
      assert.equals(0, #task.created)
    end)

    it("retries once after 1 s then reports backend-error", function()
      local calls = 0
      backend = function(_, _, done) calls = calls + 1 done(false) end
      local d = build(spec(UUID_B))
      d:switchTo("laptop", record())
      assert.equals(1, calls)
      assert.same({}, results)
      timer.advance(1)
      assert.equals(2, calls)
      assert.same({ { false, "backend-error" } }, results)
    end)

    it("succeeds when the retry succeeds", function()
      local calls = 0
      backend = function(_, _, done) calls = calls + 1 done(calls == 2) end
      local d = build(spec(UUID_B))
      d:switchTo("laptop", record())
      timer.advance(1)
      assert.same({ { true } }, results)
    end)

    it("ignores a second done from the same attempt", function()
      backend = function(_, _, done) done(true) done(false) end
      local d = build(spec(UUID_B))
      d:switchTo("laptop", record())
      timer.advance(5)
      assert.same({ { true } }, results)
    end)

    it("still reports not-visible", function()
      backend = function() error("must not be called") end
      screens = {}
      local d = build(spec(UUID_B))
      d:switchTo("laptop", record())
      assert.same({ { false, "not-visible" } }, results)
    end)
  end)

  describe("cancel", function()
    it("stops the retry timer: no second attempt and no done after cancel", function()
      local d = build(spec(UUID_A), { { 1, "", "err" }, { 0, "", "" } })
      d:switchTo("laptop", record())
      timer.advance(0) -- the first attempt failed, the retry is waiting
      d:cancel()
      timer.advance(10)
      assert.equals(1, #task.created)
      assert.same({}, results)
      assert.equals(0, timer.pending())
    end)

    it("terminates the task in flight without calling done", function()
      local d = build(spec(UUID_A), { { 0, "", "" } }, 100)
      d:switchTo("laptop", record())
      assert.is_true(task.created[1].running)
      d:cancel()
      assert.is_true(task.created[1].terminated)
      timer.advance(200)
      assert.equals(1, #task.created)
      assert.same({}, results)
      assert.equals(0, timer.pending())
    end)

    it("does not call done when a function backend answers late", function()
      local late
      backend = function(_, _, done) late = done end
      local d = build(spec(UUID_B))
      d:switchTo("laptop", record())
      d:cancel()
      late(true)
      assert.same({}, results)
    end)

    it("does not retry a function backend that failed before the cancel", function()
      local calls = 0
      backend = function(_, _, done) calls = calls + 1 done(false) end
      local d = build(spec(UUID_B))
      d:switchTo("laptop", record())
      d:cancel()
      timer.advance(5)
      assert.equals(1, calls)
      assert.same({}, results)
    end)

    it("cancels every switch in flight and leaves the display usable", function()
      local d = build(spec(UUID_A), {}, 1)
      d:switchTo("laptop", record())
      d:switchTo("desk-mini", record())
      d:cancel()
      assert.is_true(task.created[1].terminated)
      assert.is_true(task.created[2].terminated)
      d:switchTo("laptop", record())
      timer.advance(1)
      assert.same({ { true } }, results)
    end)

    it("does nothing when nothing is pending", function()
      local d = build(spec(UUID_A))
      d:cancel()
      d:switchTo("laptop", record())
      timer.advance(0)
      assert.same({ { true } }, results)
    end)
  end)

  describe("function backends that raise", function()
    it("treats an error in switchTo as a failed attempt, retries once, then reports backend-error", function()
      local calls, errors = 0, {}
      logger = { e = function(msg) errors[#errors + 1] = msg end }
      backend = function() calls = calls + 1 error("boom") end
      local d = build(spec(UUID_B))
      d:switchTo("laptop", record())
      assert.equals(1, calls)
      assert.same({}, results)
      timer.advance(1)
      assert.equals(2, calls)
      assert.same({ { false, "backend-error" } }, results)
      assert.equals(2, #errors)
      assert.matches("boom", errors[1])
    end)

    it("succeeds when the retry after an error succeeds", function()
      local calls = 0
      backend = function(_, _, done)
        calls = calls + 1
        if calls == 1 then error("first") end
        done(true)
      end
      local d = build(spec(UUID_B))
      d:switchTo("laptop", record())
      timer.advance(1)
      assert.same({ { true } }, results)
    end)

    it("treats an error in switchToSync as backend-error", function()
      backend = function() error("boom") end
      local ok, reason = build(spec(UUID_B)):switchToSync("laptop", 3)
      assert.is_false(ok)
      assert.equals("backend-error", reason)
    end)

    it("does not need a logger", function()
      backend = function() error("boom") end
      local ok, reason = build(spec(UUID_B)):switchToSync("laptop", 3)
      assert.is_false(ok)
      assert.equals("backend-error", reason)
    end)
  end)

  describe("switchToSync", function()
    it("runs the backend once and returns true on success", function()
      local d = build(spec(UUID_A), { { 0, "", "" } }, 0.1)
      local ok, reason = d:switchToSync("laptop", 3)
      assert.is_true(ok)
      assert.is_nil(reason)
      assert.same({ "display", UUID_A, "set", "input", "16" }, task.created[1].args)
    end)

    it("does not retry and returns backend-error on failure", function()
      local d = build(spec(UUID_A), { { 1, "", "err" }, { 0, "", "" } }, 0.1)
      local ok, reason = d:switchToSync("laptop", 3)
      assert.is_false(ok)
      assert.equals("backend-error", reason)
      assert.equals(1, #task.created)
    end)

    it("returns backend-error when the task exceeds the limit", function()
      local d = build(spec(UUID_A), { { 0, "", "" } }, 100)
      local ok, reason = d:switchToSync("laptop", 3)
      assert.is_false(ok)
      assert.equals("backend-error", reason)
      assert.is_true(task.created[1].terminated)
    end)

    it("returns not-visible for a missing screen", function()
      screens = {}
      local ok, reason = build(spec(UUID_A)):switchToSync("laptop", 3)
      assert.is_false(ok)
      assert.equals("not-visible", reason)
    end)

    it("succeeds with a backend function that calls done(true) synchronously", function()
      backend = function(_, _, done) done(true) end
      local ok, reason = build(spec(UUID_B)):switchToSync("laptop", 3)
      assert.is_true(ok)
      assert.is_nil(reason)
    end)

    it("fails with a backend function that does not call done synchronously", function()
      local late
      backend = function(_, _, done) late = done end
      local ok, reason = build(spec(UUID_B)):switchToSync("laptop", 3)
      assert.is_false(ok)
      assert.equals("backend-error", reason)
      late(true)
    end)

    it("warns once when a backend function returns without having called done", function()
      local warnings = {}
      logger = { w = function(msg) warnings[#warnings + 1] = msg end }
      backend = function() end
      local d = build(spec(UUID_B))
      d:switchToSync("laptop", 3)
      d:switchToSync("laptop", 3)
      assert.equals(1, #warnings)
      assert.matches("done", warnings[1])
      assert.matches("synchronous", warnings[1])
    end)

    it("does not warn when the backend function calls done before returning", function()
      local warnings = {}
      logger = { w = function(msg) warnings[#warnings + 1] = msg end }
      backend = function(_, _, done) done(true) end
      build(spec(UUID_B)):switchToSync("laptop", 3)
      assert.same({}, warnings)
    end)

    it("fails with a backend function that reports failure", function()
      backend = function(_, _, done) done(false) end
      local ok, reason = build(spec(UUID_B)):switchToSync("laptop", 3)
      assert.is_false(ok)
      assert.equals("backend-error", reason)
    end)
  end)
end)
