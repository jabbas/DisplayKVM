local fakes = dofile("spec/support/fakes.lua")
local Runner = dofile("runner.lua")

describe("Runner", function()
  local timer, task, runner

  -- Fake tasks complete `latency` seconds after start when the fake clock advances; latency nil means never.
  local function build(script, latency)
    timer = fakes.timer()
    task = fakes.task(script, { timer = latency and timer or nil, latency = latency })
    runner = Runner.new({
      task = task,
      timer = timer,
      usleep = function(us) timer.advance(us / 1000000) end,
      clock = timer.now,
    })
  end

  describe("run", function()
    it("reports success on exit code 0 with the stdout", function()
      build({ { 0, "out", "" } }, 0)
      local calls = {}
      runner:run("/bin/x", { "a", "b" }, 5, function(ok, out) calls[#calls + 1] = { ok, out } end)
      assert.equals("/bin/x", task.created[1].path)
      assert.same({ "a", "b" }, task.created[1].args)
      assert.is_true(task.created[1].started)
      assert.same({}, calls)
      timer.advance(0)
      assert.same({ { true, "out" } }, calls)
    end)

    it("reports failure with stderr on a non-zero exit code", function()
      build({ { 1, "o", "boom" } }, 0)
      local calls = {}
      runner:run("/bin/x", {}, 5, function(ok, out) calls[#calls + 1] = { ok, out } end)
      timer.advance(0)
      assert.same({ { false, "boom" } }, calls)
    end)

    it("terminates on timeout and calls done exactly once with 'timeout'", function()
      build({ { 0, "late", "" } }, 10)
      local calls = {}
      runner:run("/bin/x", {}, 5, function(ok, out) calls[#calls + 1] = { ok, out } end)
      timer.advance(4.9)
      assert.same({}, calls)
      timer.advance(0.2)
      assert.same({ { false, "timeout" } }, calls)
      assert.is_true(task.created[1].terminated)
      timer.advance(20)
      assert.same({ { false, "timeout" } }, calls)
    end)

    it("ignores a task completion that arrives after the timeout", function()
      build({ { 0, "late", "" } })
      local calls = {}
      runner:run("/bin/x", {}, 5, function(ok, out) calls[#calls + 1] = { ok, out } end)
      timer.advance(5)
      assert.same({ { false, "timeout" } }, calls)
      task.created[1].callback(0, "late", "")
      assert.same({ { false, "timeout" } }, calls)
    end)

    it("cancels the timeout timer once the task has finished", function()
      build({ { 0, "", "" } }, 0)
      runner:run("/bin/x", {}, 5, function() end)
      timer.advance(0)
      assert.equals(0, timer.pending())
    end)

    it("reports a task that cannot be started", function()
      build()
      task.new = function() error("no such file") end
      local calls = {}
      runner:run("/missing", {}, 5, function(ok, out) calls[#calls + 1] = { ok, out } end)
      assert.same({ { false, "start-failed" } }, calls)
    end)
  end)

  describe("runSync", function()
    it("returns true when the task exits with 0", function()
      build({ { 0, "", "" } }, 0.1)
      local ok = runner:runSync("/bin/x", { "a" }, 2)
      assert.is_true(ok)
      assert.same({ "a" }, task.created[1].args)
    end)

    it("returns false when the task exits non-zero", function()
      build({ { 3, "", "bad" } }, 0.1)
      local ok, out = runner:runSync("/bin/x", {}, 2)
      assert.is_false(ok)
      assert.is_string(out)
    end)

    it("terminates a task that outlives the limit and returns 'timeout'", function()
      build({ { 0, "", "" } }, 100)
      local ok, out = runner:runSync("/bin/x", {}, 2)
      assert.is_false(ok)
      assert.equals("timeout", out)
      assert.is_true(task.created[1].terminated)
      assert.is_true(timer.now() >= 2)
      assert.is_true(timer.now() < 2.1)
    end)

    it("returns false when the task cannot be started", function()
      build()
      task.new = function() error("no such file") end
      local ok, out = runner:runSync("/missing", {}, 2)
      assert.is_false(ok)
      assert.equals("start-failed", out)
    end)
  end)
end)
