local json = require("dkjson")
local Gen = dofile("tools/gen-docs-json.lua")

local function readAll(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("a")
  f:close()
  return s
end

describe("gen-docs-json", function()
  it("describes the Spoon in init.lua", function()
    local source = readAll("init.lua")
    local docs = assert(json.decode(Gen.generate(source)))
    assert.equals(1, #docs)
    assert.equals("DisplayKVM", docs[1].name)
    assert.equals(source:match('\nobj%.version = "([^"]+)"'), docs[1].version)
    assert.matches("^%d+%.%d+%.%d+$", docs[1].version)
    assert.equals("https://github.com/jabbas/DisplayKVM", docs[1].homepage)
    assert.truthy(docs[1].desc:find("Shares one or more monitors between several Macs", 1, true))
    assert.is_nil(docs[1].desc:find("Basic usage", 1, true))
  end)

  it("escapes JSON special characters", function()
    local src = '--- === Foo ===\n---\n--- Says "hi" \\ there.\n\nobj.name = "Foo"\nobj.version = "1.0"\n'
    local docs = assert(json.decode(Gen.generate(src)))
    assert.equals('Says "hi" \\ there.', docs[1].desc)
  end)

  it("fails without name or version", function()
    assert.has_error(function() Gen.generate("--- === Foo ===\n") end)
  end)
end)
