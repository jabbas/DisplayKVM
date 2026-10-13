-- Signed message envelope: build, verify, time window and replay protection.
-- Pure module: HMAC, clock, randomness and JSON codec are injected.

local Message = {}
Message.__index = Message

local VERSION = 1

-- Compares two strings without leaving early on the first differing byte.
function Message.constantTimeEqual(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do
    if a:byte(i) ~= b:byte(i) then diff = diff + 1 end
  end
  return diff == 0
end

function Message.new(deps)
  local self = setmetatable({}, Message)
  self.secret = deps.secret
  self.node = deps.node
  self.instance = deps.instance
  self.hmac = deps.hmac
  self.now = deps.now
  self.random = deps.random
  self.codec = deps.codec
  self.window = deps.window or 30000
  self.nonceTtl = deps.nonceTtl or 60000
  self.nonces = {} -- nonce -> expiry (ms)
  return self
end

function Message:build(type, body)
  local raw = self.codec.encode({
    v = VERSION,
    from = self.node,
    instance = self.instance,
    ts = self.now(),
    nonce = self.random(16),
    type = type,
    body = body,
  })
  return raw, self.hmac(self.secret, raw)
end

function Message:_purge(now)
  for nonce, expiry in pairs(self.nonces) do
    if expiry < now then self.nonces[nonce] = nil end
  end
end

-- Returns msg, or nil + reason ("bad-signature" | "malformed" | "stale" | "replay" | "self").
-- On "stale" the third value is the sender's name (for clock-skew logging).
function Message:verify(raw, sig)
  local now = self.now()
  self:_purge(now)

  if type(raw) ~= "string" or not Message.constantTimeEqual(self.hmac(self.secret, raw), sig) then
    return nil, "bad-signature"
  end

  local ok, msg = pcall(self.codec.decode, raw)
  if not ok or type(msg) ~= "table" or msg.v ~= VERSION
    or type(msg.from) ~= "string" or type(msg.instance) ~= "string"
    or type(msg.ts) ~= "number" or type(msg.nonce) ~= "string"
    or type(msg.type) ~= "string" or type(msg.body) ~= "table" then
    return nil, "malformed"
  end

  if math.abs(now - msg.ts) > self.window then return nil, "stale", msg.from end
  if self.nonces[msg.nonce] ~= nil then return nil, "replay" end
  if msg.from == self.node then return nil, "self" end

  self.nonces[msg.nonce] = now + self.nonceTtl
  return msg
end

-- Test-only helper: number of nonces currently remembered.
function Message:_nonceCount()
  local n = 0
  for _ in pairs(self.nonces) do n = n + 1 end
  return n
end

return Message
