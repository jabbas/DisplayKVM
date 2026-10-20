local fakes = dofile("spec/support/fakes.lua")
local Away = dofile("away.lua")

describe("Away", function()
  local timer, screens, windows, log

  local function screen(uuid, mirrorResult)
    local s = { uuid = uuid, mirrorCalls = {}, stopCalls = 0 }
    function s:getUUID() return self.uuid end
    function s:mirrorOf(other)
      self.mirrorCalls[#self.mirrorCalls + 1] = other
      return mirrorResult ~= false
    end
    function s:mirrorStop()
      self.stopCalls = self.stopCalls + 1
      return mirrorResult ~= false
    end
    return s
  end

  local function window(fails)
    local w = { ensured = 0 }
    -- hs.window has no ensureIsInScreenBounds; setFrameInScreenBounds() without a rect re-applies the
    -- current frame, clamped to the screen.
    function w:setFrameInScreenBounds()
      self.ensured = self.ensured + 1
      if fails then error("window gone") end
    end
    return w
  end

  local function build(primaryIndex)
    timer = fakes.timer()
    windows = {}
    log = { lines = {} }
    for _, level in ipairs({ "d", "i", "w", "e" }) do
      log[level] = function(msg) log.lines[#log.lines + 1] = level .. " " .. msg end
    end
    return Away.new({
      find = function(uuid)
        for _, s in ipairs(screens) do
          if s.uuid == uuid then return s end
        end
        return nil
      end,
      primary = function() return screens[primaryIndex or 1] end,
      all = function() return screens end,
      windows = function() return windows end,
      timer = timer,
      log = log,
      settle = 2,
    })
  end

  it("runs without a global hs", function()
    assert.is_nil(_G.hs)
  end)

  describe("mirror", function()
    it("mirrors the source onto the primary screen when that is not the source", function()
      local source, primary, other = screen("SRC"), screen("PRIMARY"), screen("OTHER")
      screens = { other, primary, source }
      local away = build(2)
      local ok, used = away:mirror("SRC", nil)
      assert.is_true(ok)
      assert.equal("PRIMARY", used)
      assert.same({ primary }, source.mirrorCalls)
    end)

    it("takes the first other screen when the primary is the source", function()
      local source, other, third = screen("SRC"), screen("OTHER"), screen("THIRD")
      screens = { source, other, third }
      local away = build(1)
      local ok, used = away:mirror("SRC", nil)
      assert.is_true(ok)
      assert.equal("OTHER", used)
      assert.same({ other }, source.mirrorCalls)
    end)

    it("prefers an explicit target uuid", function()
      local source, primary, chosen = screen("SRC"), screen("PRIMARY"), screen("CHOSEN")
      screens = { source, primary, chosen }
      local away = build(2)
      local ok, used = away:mirror("SRC", "CHOSEN")
      assert.is_true(ok)
      assert.equal("CHOSEN", used)
      assert.same({ chosen }, source.mirrorCalls)
    end)

    it("fails without an error when the source or the explicit target is gone", function()
      local primary = screen("PRIMARY")
      screens = { primary }
      local away = build(1)
      assert.is_false(away:mirror("SRC", nil))
      assert.is_false(away:mirror("PRIMARY", "NOPE"))
      assert.same({}, primary.mirrorCalls)
      assert.equal(0, timer.pending())
    end)

    it("fails when the resolved target has no uuid, without calling mirrorOf or scheduling anything", function()
      local source, nameless = screen("SRC"), screen(nil)
      screens = { source, nameless }
      local away = build(2)
      assert.is_false(away:mirror("SRC", nil))
      assert.same({}, source.mirrorCalls)
      assert.equal(0, timer.pending())
    end)

    it("fails when there is no other screen to mirror onto", function()
      screens = { screen("SRC") }
      local away = build(1)
      assert.is_false(away:mirror("SRC", nil))
    end)

    it("returns false and keeps the windows alone when mirrorOf fails", function()
      screens = { screen("SRC", false), screen("PRIMARY") }
      local away = build(2)
      local w = window()
      windows = { w }
      assert.is_false(away:mirror("SRC", nil))
      timer.advance(10)
      assert.equal(0, w.ensured)
    end)

    it("pulls every window back into bounds after the settle delay, a failing window does not stop the rest", function()
      screens = { screen("SRC"), screen("PRIMARY") }
      local away = build(2)
      local bad, good = window(true), window()
      windows = { bad, good }
      assert.is_true(away:mirror("SRC", nil))
      timer.advance(1.9)
      assert.equal(0, good.ensured)
      timer.advance(0.2)
      assert.equal(1, bad.ensured)
      assert.equal(1, good.ensured)
    end)
  end)

  describe("defaultTarget", function()
    it("is the primary screen, or the first other screen when the primary is excluded", function()
      screens = { screen("A"), screen("B") }
      local away = build(2)
      assert.equal("B", away:defaultTarget(nil))
      assert.equal("A", away:defaultTarget("B"))
    end)

    it("is nil when there is no suitable screen", function()
      screens = { screen("A") }
      local away = build(1)
      assert.is_nil(away:defaultTarget("A"))
    end)
  end)

  describe("unmirror", function()
    it("calls mirrorStop on the target screen", function()
      local source, target = screen("SRC"), screen("PRIMARY")
      screens = { source, target }
      local away = build(2)
      assert.is_true(away:unmirror("PRIMARY"))
      assert.equal(1, target.stopCalls)
      assert.equal(0, source.stopCalls)
    end)

    it("returns false without an error when the screen is gone", function()
      screens = { screen("SRC") }
      local away = build(1)
      assert.is_false(away:unmirror("NOPE"))
    end)

    it("returns false when mirrorStop fails", function()
      screens = { screen("PRIMARY", false) }
      local away = build(1)
      assert.is_false(away:unmirror("PRIMARY"))
    end)

    it("cancels a pending window pull-back even when the screen is gone", function()
      screens = { screen("SRC"), screen("PRIMARY") }
      local away = build(2)
      local w = window()
      windows = { w }
      away:mirror("SRC", nil)
      assert.is_false(away:unmirror("NOPE"))
      assert.equal(0, timer.pending())
      timer.advance(10)
      assert.equal(0, w.ensured)
    end)

    it("cancels a pending window pull-back", function()
      screens = { screen("SRC"), screen("PRIMARY") }
      local away = build(2)
      local w = window()
      windows = { w }
      away:mirror("SRC", nil)
      away:unmirror("PRIMARY")
      timer.advance(10)
      assert.equal(0, w.ensured)
    end)
  end)
end)
