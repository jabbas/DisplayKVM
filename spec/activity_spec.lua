local fakes = dofile("spec/support/fakes.lua")
local ActivitySensor = dofile("activity.lua")

describe("ActivitySensor.classify", function()
  local classify = ActivitySensor.classify

  it("treats unlock as active regardless of idle", function()
    assert.are.same({ "active", false }, { classify("screensDidUnlock", true, 100, 5) })
  end)

  for _, event in ipairs({ "screensDidWake", "systemDidWake" }) do
    it(event .. " is active only when unlocked and recently used", function()
      assert.are.same({ "active", false }, { classify(event, false, 4.9, 5) })
      assert.is_nil((classify(event, false, 5, 5)))
      assert.is_nil((classify(event, true, 0, 5)))
    end)
  end

  for _, event in ipairs({ "screensDidLock", "screensDidSleep" }) do
    it(event .. " is inactive and asynchronous", function()
      assert.are.same({ "inactive", false }, { classify(event, false, 0, 5) })
    end)
  end

  it("systemWillSleep is inactive and synchronous", function()
    assert.are.same({ "inactive", true }, { classify("systemWillSleep", false, 0, 5) })
  end)

  it("ignores other events", function()
    assert.is_nil((classify("screensaverDidStart", false, 0, 5)))
    assert.is_nil((classify("sessionDidBecomeActive", false, 0, 5)))
  end)
end)

describe("ActivitySensor.initialState", function()
  it("is active when unlocked and idle below startIdle", function()
    assert.is_true(ActivitySensor.initialState(false, 29.9, 30))
    assert.is_false(ActivitySensor.initialState(false, 30, 30))
    assert.is_false(ActivitySensor.initialState(true, 0, 30))
  end)
end)

describe("ActivitySensor instance", function()
  local caffeinate, host, sensor, events

  before_each(function()
    caffeinate = fakes.caffeinate()
    host = fakes.host(0)
    sensor = ActivitySensor.new({ caffeinate = caffeinate, host = host, userIdle = 5, startIdle = 30 })
    events = {}
    sensor:start(function(active, reason, sync) events[#events + 1] = { active, reason, sync } end)
  end)

  it("runs without a global hs", function()
    assert.is_nil(_G.hs)
  end)

  it("isLocked reads CGSSessionScreenIsLocked == true only", function()
    assert.is_false(sensor:isLocked())
    caffeinate.locked = true
    assert.is_true(sensor:isLocked())
    caffeinate.noProps = true
    assert.is_false(sensor:isLocked())
  end)

  it("initial reports start / start (idle)", function()
    host.idle = 29
    assert.are.same({ true, "start" }, { sensor:initial() })
    host.idle = 30
    assert.are.same({ false, "start (idle)" }, { sensor:initial() })
    host.idle = 0
    caffeinate.locked = true
    assert.are.same({ false, "start (idle)" }, { sensor:initial() })
  end)

  it("forwards classified events using the event name as reason", function()
    caffeinate.emit("screensDidUnlock")
    caffeinate.emit("screensDidLock")
    caffeinate.emit("systemWillSleep")
    assert.are.same({
      { true, "screensDidUnlock", false },
      { false, "screensDidLock", false },
      { false, "systemWillSleep", true },
    }, events)
  end)

  it("uses live lock and idle state for wake events", function()
    host.idle = 60
    caffeinate.emit("screensDidWake")
    assert.are.same({}, events)
    host.idle = 1
    caffeinate.emit("systemDidWake")
    assert.are.same({ { true, "systemDidWake", false } }, events)
    caffeinate.locked = true
    caffeinate.emit("screensDidWake")
    assert.are.equal(1, #events)
  end)

  it("ignores unmapped events and stops delivering after stop", function()
    caffeinate.watchers[1].fn(999)
    assert.are.same({}, events)
    sensor:stop()
    caffeinate.emit("screensDidUnlock")
    assert.are.same({}, events)
    assert.is_true(caffeinate.watchers[1].stopped)
  end)
end)
