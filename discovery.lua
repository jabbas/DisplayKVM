-- Peer discovery: Bonjour (publish + browse) plus statically configured "host:port" peers.
-- Bonjour peers are named by their TXT `node` value; static peers by their "host:port" string.

local Discovery = {}
Discovery.__index = Discovery

local SERVICE_TYPE = "_displaykvm._tcp."
local DOMAIN = "local."
local RESOLVE_TIMEOUT = 5
local noop = function() end
local nullLog = { d = noop, i = noop, w = noop, e = noop }

local function parseAddress(s)
  local host, port = tostring(s):match("^([^:%s]+):(%d+)$")
  if host == nil then return nil end
  return { host = host, port = tonumber(port) }
end

-- cfg: {bonjour, node, port, groupId, staticPeers = {"host:port"}, enabled = true, log = optional}
function Discovery.new(cfg)
  local self = setmetatable({}, Discovery)
  self.bonjour = cfg.bonjour
  self.node = cfg.node
  self.port = cfg.port
  self.groupId = cfg.groupId
  self.enabled = cfg.enabled ~= false
  self.log = cfg.log or nullLog
  self.static = {}      -- address string -> {host, port}
  self.staticOrder = {}
  for _, entry in ipairs(cfg.staticPeers or {}) do
    local addr = parseAddress(entry)
    if addr and self.static[entry] == nil then
      self.static[entry] = addr
      self.staticOrder[#self.staticOrder + 1] = entry
    end
  end
  self.peers = {}       -- node name -> {host, port}
  self.services = {}    -- service name -> node name
  self.pending = {}     -- service objects being resolved (kept referenced)
  self.aliases = {}     -- node name -> static address
  return self
end

function Discovery:_serviceCount(node)
  local n = 0
  for _, owner in pairs(self.services) do
    if owner == node then n = n + 1 end
  end
  return n
end

function Discovery:_onResolved(svc, onUp)
  local txt = svc:txtRecord()
  if type(txt) ~= "table" or txt.v ~= "1" or txt.group ~= self.groupId or txt.node == nil then
    self.log.d("ignoring service " .. tostring(svc:name()) .. ": not a DisplayKVM peer of this group")
    return
  end
  local node = txt.node
  if node == self.node then return end
  local known = self.peers[node] ~= nil
  self.peers[node] = { host = svc:hostname(), port = svc:port() }
  self.services[svc:name()] = node
  if not known then onUp(node) end
end

-- Our own published service shows up in the browse results and cannot be resolved. Bonjour may
-- have renamed it on a collision, so compare against the name it actually has now.
function Discovery:_isOwnService(svc)
  local own = self.service
  if own == nil then return false end
  if svc == own then return true end
  local ok, name = pcall(svc.name, svc)
  local okOwn, ownName = pcall(own.name, own)
  return ok and okOwn and name ~= nil and name == ownName
end

function Discovery:_browse(onUp, onDown)
  self.browser = self.bonjour.new()
  self.browser:findServices(SERVICE_TYPE, DOMAIN, function(_, _, added, svc)
    if added then
      if self:_isOwnService(svc) then return end
      self.pending[svc] = true
      local ok, resolveErr = pcall(svc.resolve, svc, RESOLVE_TIMEOUT, function(s, event, err)
        self.pending[svc] = nil
        if event == "resolved" then
          self:_onResolved(s, onUp)
        else
          self.log.d("could not resolve service " .. tostring(svc:name()) .. ": " .. tostring(err or event))
        end
      end)
      if not ok then
        self.pending[svc] = nil
        self.log.d("could not resolve service: " .. tostring(resolveErr))
      end
    else
      self.pending[svc] = nil
      local name = svc:name()
      local node = self.services[name]
      if node == nil then return end
      self.services[name] = nil
      if self:_serviceCount(node) == 0 and self.peers[node] ~= nil then
        self.peers[node] = nil
        onDown(node)
      end
    end
  end)
end

function Discovery:start(onUp, onDown)
  onUp = onUp or noop
  onDown = onDown or noop
  if self.enabled then
    self.service = self.bonjour.service.new(self.node, SERVICE_TYPE, self.port)
    self.service:txtRecord({ v = "1", group = self.groupId, node = self.node })
    self.service:publish()
    self:_browse(onUp, onDown)
  end
  for _, name in ipairs(self.staticOrder) do onUp(name) end
end

function Discovery:stop()
  if self.browser then self.browser:stop() self.browser = nil end
  if self.service then self.service:stop() self.service = nil end
  self.peers, self.services, self.pending = {}, {}, {}
end

function Discovery:names()
  local out = {}
  for node in pairs(self.peers) do out[#out + 1] = node end
  for _, address in ipairs(self.staticOrder) do
    local covered = false
    for node, aliased in pairs(self.aliases) do
      if aliased == address and self.peers[node] ~= nil then covered = true end
    end
    if not covered then out[#out + 1] = address end
  end
  table.sort(out)
  return out
end

-- Bonjour first, then aliases, then a static address.
function Discovery:resolve(name)
  local peer = self.peers[name]
  if peer then return { host = peer.host, port = peer.port } end
  local address = self.aliases[name] or name
  local addr = self.static[address]
  if addr then return { host = addr.host, port = addr.port } end
  return nil
end

function Discovery:alias(nodeName, addressName)
  if self.static[addressName] ~= nil then self.aliases[nodeName] = addressName end
end

-- Static addresses with no learned alias to a node for which `isAlive(node)` holds. The node name
-- behind an address is only learned from a signed 200 reply, so these still need a `hello`.
function Discovery:unaliased(isAlive)
  local out = {}
  for _, address in ipairs(self.staticOrder) do
    local learned = false
    for node, aliased in pairs(self.aliases) do
      if aliased == address and isAlive(node) then learned = true end
    end
    if not learned then out[#out + 1] = address end
  end
  return out
end

return Discovery
