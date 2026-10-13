local m1ddc = dofile("backends/m1ddc.lua")
local ddcctl = dofile("backends/ddcctl.lua")
local betterdisplay = dofile("backends/betterdisplay.lua")
local lunar = dofile("backends/lunar.lua")

local TARGET = { uuid = "37D8832A-2D66-02CA-B9F7-8F30A301B230", name = "DELL U2720Q (2)" }

describe("backends", function()
  it("expose name, defaultPath and args", function()
    for _, b in ipairs({ m1ddc, ddcctl, betterdisplay, lunar }) do
      assert.is_string(b.name)
      assert.is_string(b.defaultPath)
      assert.is_function(b.args)
    end
  end)

  describe("m1ddc", function()
    it("addresses the display by UUID", function()
      assert.equals("m1ddc", m1ddc.name)
      assert.equals("/opt/homebrew/bin/m1ddc", m1ddc.defaultPath)
      assert.same({ "display", "U-1", "set", "input", "16" }, m1ddc.args({ uuid = "U-1" }, 16, {}))
    end)

    it("ignores inputAlt", function()
      assert.same({ "display", "U-1", "set", "input", "16" }, m1ddc.args({ uuid = "U-1" }, 16, { inputAlt = true }))
    end)
  end)

  describe("ddcctl", function()
    it("selects the display by index (default 1) and sets the input", function()
      assert.equals("ddcctl", ddcctl.name)
      assert.equals("/opt/homebrew/bin/ddcctl", ddcctl.defaultPath)
      assert.same({ "-d", "1", "-i", "17" }, ddcctl.args(TARGET, 17, {}))
    end)

    it("honours opts.index", function()
      assert.same({ "-d", "2", "-i", "15" }, ddcctl.args(TARGET, 15, { index = 2 }))
    end)
  end)

  describe("betterdisplay", function()
    it("addresses the display by UUID and sends the DDC input-select code", function()
      assert.equals("betterdisplay", betterdisplay.name)
      assert.equals("/opt/homebrew/bin/betterdisplaycli", betterdisplay.defaultPath)
      assert.same({
        "set", "--UUID=37D8832A-2D66-02CA-B9F7-8F30A301B230", "--feature=ddc", "--vcp=inputSelect", "--value=16",
      }, betterdisplay.args(TARGET, 16, {}))
    end)

    it("uses the alternate addressing with inputAlt", function()
      assert.same({
        "set", "--UUID=37D8832A-2D66-02CA-B9F7-8F30A301B230", "--feature=ddcAlt", "--vcp=inputSelectAlt", "--value=16",
      }, betterdisplay.args(TARGET, 16, { inputAlt = true }))
    end)
  end)

  describe("lunar", function()
    it("selects the display by name and sets the input", function()
      assert.equals("lunar", lunar.name)
      assert.equals("/Applications/Lunar.app/Contents/MacOS/Lunar", lunar.defaultPath)
      assert.same({ "displays", "DELL U2720Q (2)", "input", "16" }, lunar.args(TARGET, 16, {}))
    end)
  end)
end)
