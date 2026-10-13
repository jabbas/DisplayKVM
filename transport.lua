-- Signed HTTP transport: `POST /v1/msg` server plus async and sync clients.
-- Hammerspoon modules (httpserver, http, timer), the message codec, discovery, clock and logger are injected.

local Transport = {}
Transport.__index = Transport

local PATH = "/v1/msg"
local SIG_HEADER = "X-DisplayKVM-Sig"
local LOG_INTERVAL_MS = 60000
local noop = function() end

local function header(headers, name)
  if type(headers) ~= "table" then return nil end
  name = name:lower()
  for key, value in pairs(headers) do
    if type(key) == "string" and key:lower() == name then return value end
  end
  return nil
end

local function isAddress(name)
  return name:match("^[^:%s]+:%d+$") ~= nil
end

-- deps: {httpserver, http, timer, message, discovery, port, interface, log, now, softTimeout = 5}
function Transport.new(deps)
  local self = setmetatable({}, Transport)
  self.httpserver = deps.httpserver
  self.http = deps.http
  self.timer = deps.timer
  self.message = deps.message
  self.discovery = deps.discovery
  self.port = deps.port
  self.interface = deps.interface
  self.log = deps.log
  self.now = deps.now
  self.softTimeout = deps.softTimeout or 5
  self.lastLogged = {} -- rejection reason -> ms of last log entry
  return self
end

function Transport:_rejected(reason, from)
  local now = self.now()
  local last = self.lastLogged[reason]
  if last ~= nil and now - last < LOG_INTERVAL_MS then return end
  self.lastLogged[reason] = now
  if reason == "stale" then
    self.log.w("clock skew with " .. tostring(from))
  else
    self.log.d("rejected message: " .. tostring(reason))
  end
end

function Transport:_handle(method, path, headers, body)
  if method ~= "POST" or path ~= PATH then return "", 404, {} end

  local msg, reason, from = self.message:verify(body, header(headers, SIG_HEADER))
  if not msg then
    self:_rejected(reason, from)
    return "", 401, {}
  end

  local ok, status, replyBody = pcall(self.onMessage, msg)
  if not ok then
    self.log.e("message handler failed: " .. tostring(status))
    return "", 500, {}
  end
  if replyBody == nil then return "", status, {} end

  local raw, sig = self.message:build("reply", replyBody)
  return raw, status, { ["Content-Type"] = "application/json", [SIG_HEADER] = sig }
end

function Transport:start(onMessage, onSeen)
  self.onMessage = onMessage
  self.onSeen = onSeen or noop
  local server = self.httpserver.new(false, false)
  server:setPort(self.port)
  if self.interface ~= nil then server:setInterface(self.interface) end
  server:setCallback(function(method, path, headers, body)
    return self:_handle(method, path, headers, body)
  end)
  server:start()
  self.server = server
end

function Transport:stop()
  if self.server then
    self.server:stop()
    self.server = nil
  end
end

-- Returns url, raw, headers for a message to `peerName`, or nil when the peer is unknown.
function Transport:_prepare(peerName, msgType, body)
  local addr = self.discovery:resolve(peerName)
  if not addr then return nil end
  local raw, sig = self.message:build(msgType, body)
  local url = "http://" .. addr.host .. ":" .. addr.port .. PATH
  return url, raw, { ["Content-Type"] = "application/json", [SIG_HEADER] = sig }
end

-- cb(ok, reply, status) is called exactly once.
function Transport:send(peerName, msgType, body, cb)
  local url, raw, headers = self:_prepare(peerName, msgType, body)
  if not url then
    cb(false, nil, "unknown-peer")
    return
  end

  local done, timeout = false, nil
  local function finish(ok, reply, status)
    if done then return end
    done = true
    if timeout then timeout:stop() end
    cb(ok, reply, status)
  end

  local function onResponse(status, resBody, resHeaders)
    if done then return end
    if status == 204 then
      finish(true, nil, 204)
    elseif status == 200 then
      local reply = self.message:verify(resBody, header(resHeaders, SIG_HEADER))
      if not reply or reply.type ~= "reply" then
        finish(false, nil, "bad-reply")
        return
      end
      if isAddress(peerName) then self.discovery:alias(reply.from, peerName) end
      self.onSeen(reply.from)
      finish(true, reply.body, 200)
    elseif status == 401 then
      self.log.w("401 from " .. peerName .. " (check shared secret and NTP clock sync)")
      finish(false, nil, 401)
    else
      finish(false, nil, status)
    end
  end

  timeout = self.timer.doAfter(self.softTimeout, function() finish(false, nil, "timeout") end)
  self.http.asyncPost(url, raw, headers, onResponse)
end

-- Blocking send for the sleep path only: hs.http.doRequest has no timeout of its own.
-- `timeoutSec` is accepted for API symmetry. Returns true when the peer acknowledged.
function Transport:sendSync(peerName, msgType, body, _)
  local ok, result = pcall(function()
    local url, raw, headers = self:_prepare(peerName, msgType, body)
    if not url then return false end
    local status = self.http.doRequest(url, "POST", raw, headers)
    return status == 200 or status == 204
  end)
  if not ok then
    self.log.d("sync send to " .. tostring(peerName) .. " failed: " .. tostring(result))
    return false
  end
  return result == true
end

-- Sends to every known peer, one after another. Returns how many acknowledged.
function Transport:broadcastSync(msgType, body, timeoutSec)
  local okCount = 0
  for _, name in ipairs(self.discovery:names()) do
    if self:sendSync(name, msgType, body, timeoutSec) then okCount = okCount + 1 end
  end
  return okCount
end

return Transport
