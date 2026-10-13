local Instances = dofile("instances.lua")

describe("Instances", function()
  local inst

  before_each(function() inst = Instances.new(60000) end)

  it("reports the first and repeated instance of a node", function()
    assert.equal("first", inst:observe("laptop", "a", 0))
    assert.equal("same", inst:observe("laptop", "a", 1000))
  end)

  it("lets a new instance replace the old one without an alarm, even right after a heartbeat", function()
    inst:observe("laptop", "a", 0)
    assert.equal("replaced", inst:observe("laptop", "b", 5000))
    assert.equal("same", inst:observe("laptop", "b", 6000))
  end)

  it("flags an older instance heard again within the window as a duplicate", function()
    inst:observe("laptop", "a", 0)
    inst:observe("laptop", "b", 5000)
    assert.equal("duplicate", inst:observe("laptop", "a", 30000))
  end)

  it("ignores an older instance heard after the window", function()
    inst:observe("laptop", "a", 0)
    inst:observe("laptop", "b", 5000)
    assert.equal("stale", inst:observe("laptop", "a", 65001))
  end)

  it("keeps nodes independent", function()
    inst:observe("laptop", "a", 0)
    assert.equal("first", inst:observe("studio", "a", 0))
  end)

  it("treats a missing instance as the current one", function()
    inst:observe("laptop", "a", 0)
    assert.equal("same", inst:observe("laptop", nil, 1))
  end)
end)
