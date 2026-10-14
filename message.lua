-- Signed message envelope: build, verify, time window and replay protection.
-- Pure module: HMAC, clock, randomness and JSON codec are injected.

local Message = {}
Message.__index = Message

local VERSION = 1

-- Compares two strings without leaving early on the first differing byte: no branch in the loop
-- depends on the data. A length mismatch may return at once (the length is not secret).
function Message.constantTimeEqual(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do
    diff = diff | (string.byte(a, i) ~ string.byte(b, i))
  end
  return diff == 0
end

function Message.new(deps)
  local self = setmetatable({}, Message)
  -- The secret lives only in this closure so that inspecting the object (hs.inspect) cannot reveal it.
  local secret, hmac = deps.secret, deps.hmac
  self._sign = function(raw) return hmac(secret, raw) end
  self.node = deps.node
  self.instance = deps.instance
  self.now = deps.now
  self.random = deps.random
  self.codec = deps.codec
  self.window = deps.window or 30000
  self.nonceTtl = deps.nonceTtl or 2 * self.window
  -- A nonce must outlive every timestamp that can still pass the +-window check, i.e. 2 * window.
  assert(self.nonceTtl >= 2 * self.window,
    string.format("nonceTtl (%s ms) must be at least 2 * window (%s ms)",
      tostring(self.nonceTtl), tostring(self.window)))
  self.nonces = {} -- nonce -> expiry (ms)
  return self
end

function Message:build(msgType, body)
  local raw = self.codec.encode({
    v = VERSION,
    from = self.node,
    instance = self.instance,
    ts = self.now(),
    nonce = self.random(16),
    type = msgType,
    body = body,
  })
  return raw, self._sign(raw)
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

  if type(raw) ~= "string" or not Message.constantTimeEqual(self._sign(raw), sig) then
    return nil, "bad-signature"
  end

  local ok, msg = pcall(self.codec.decode, raw)
  if not ok or type(msg) ~= "table" or msg.v ~= VERSION
    or type(msg.from) ~= "string" or type(msg.instance) ~= "string"
    or type(msg.ts) ~= "number" or type(msg.nonce) ~= "string"
    or type(msg.type) ~= "string" or type(msg.body) ~= "table"
    or msg.ts ~= msg.ts or msg.ts == math.huge or msg.ts == -math.huge then
    return nil, "malformed"
  end

  -- Floating point: an integer difference could wrap around (math.abs(math.mininteger) is negative).
  local delta = (now + 0.0) - msg.ts
  if delta > self.window or delta < -self.window then return nil, "stale", msg.from end
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
