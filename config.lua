-- Configuration validation and normalisation. Pure module: no dependency on Hammerspoon.
-- Everything environment-specific (hostname, file checks, built-in backends) is passed in via `env`.

local Config = {}

local PREFIX = "DisplayKVM: "
local MIN_SECRET_LENGTH = 64

local function fail(fmt, ...)
  return nil, PREFIX .. string.format(fmt, ...)
end

local function asInteger(v)
  if type(v) ~= "number" then return nil end
  return math.tointeger(v)
end

local function deepCopy(v)
  if type(v) ~= "table" then return v end
  local c = {}
  for k, x in pairs(v) do c[k] = deepCopy(x) end
  return c
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function validPeer(entry)
  if type(entry) ~= "string" then return false end
  local host, port = entry:match("^([^%s:]+):(%d+)$")
  if not host then return false end
  port = tonumber(port)
  return port >= 1 and port <= 65535
end

local function normaliseMatch(id, match, inputs)
  if type(match) == "string" then
    if match == "" then return fail("displays.%s.match must not be empty", id) end
    return match
  end
  if type(match) ~= "table" then
    return fail("displays.%s.match is required (string or table of node -> string)", id)
  end
  local out = {}
  for node, value in pairs(match) do
    if type(value) ~= "string" or value == "" then
      return fail("displays.%s.match.%s must be a non-empty string", id, tostring(node))
    end
    out[node] = value
  end
  for _, node in ipairs(sortedKeys(inputs)) do
    if out[node] == nil then
      return fail("displays.%s.match has no entry for node '%s' listed in inputs", id, node)
    end
  end
  return out
end

-- `control`: nodes allowed to switch the monitor via DDC. Defaults to every node in `inputs`.
-- Always returns a new, sorted, de-duplicated list.
local function normaliseControl(id, control, inputs)
  if control == nil then return sortedKeys(inputs) end
  if type(control) ~= "table" or next(control) == nil then
    return fail("displays.%s.control must be a non-empty list of node names", id)
  end
  local seen, out = {}, {}
  for k, node in pairs(control) do
    if math.type(k) ~= "integer" or k < 1 or k > #control then
      return fail("displays.%s.control must be a list of node names (bad key %s)", id, tostring(k))
    end
    if type(node) ~= "string" or inputs[node] == nil then
      return fail("displays.%s.control '%s' has no entry in inputs", id, tostring(node))
    end
    if not seen[node] then
      seen[node] = true
      out[#out + 1] = node
    end
  end
  table.sort(out)
  return out
end

-- `whenAway` / `mirrorTo`: table of node -> value, every node must have an entry in `inputs`.
-- `valid(value)` checks the value; `expected` describes it in the error message.
local function normaliseNodeMap(id, field, map, inputs, valid, expected)
  if map == nil then return {} end
  if type(map) ~= "table" then
    return fail("displays.%s.%s must be a table of node -> value", id, field)
  end
  local out = {}
  for node, value in pairs(map) do
    if type(node) ~= "string" or inputs[node] == nil then
      return fail("displays.%s.%s '%s' has no entry in inputs", id, field, tostring(node))
    end
    if not valid(value) then
      return fail("displays.%s.%s.%s must be %s", id, field, node, expected)
    end
    out[node] = value
  end
  return out
end

local function normaliseDisplay(id, d)
  if type(d) ~= "table" then return fail("displays.%s must be a table", id) end

  if type(d.inputs) ~= "table" or next(d.inputs) == nil then
    return fail("displays.%s.inputs is required (non-empty table of node -> DDC input)", id)
  end
  local inputs = {}
  for node, value in pairs(d.inputs) do
    local n = asInteger(value)
    if type(node) ~= "string" or not n then
      return fail("displays.%s.inputs.%s must map a node name to an integer", id, tostring(node))
    end
    inputs[node] = n
  end

  local match, err = normaliseMatch(id, d.match, inputs)
  if not match then return nil, err end

  local home = d.home
  if home == nil then
    home = sortedKeys(inputs)[1]
  elseif type(home) ~= "string" or inputs[home] == nil then
    return fail("displays.%s.home '%s' has no entry in inputs", id, tostring(home))
  end

  local pull = d.pull
  if pull == nil then
    pull = true
  elseif type(pull) ~= "boolean" then
    return fail("displays.%s.pull must be a boolean", id)
  end

  local control, cerr = normaliseControl(id, d.control, inputs)
  if not control then return nil, cerr end

  local whenAway, werr = normaliseNodeMap(id, "whenAway", d.whenAway, inputs, function(v)
    return v == "mirror"
  end, "\"mirror\"")
  if not whenAway then return nil, werr end

  local mirrorTo, merr = normaliseNodeMap(id, "mirrorTo", d.mirrorTo, inputs, function(v)
    return type(v) == "string" and v ~= ""
  end, "a non-empty display UUID string")
  if not mirrorTo then return nil, merr end

  return {
    match = match, inputs = inputs, home = home, pull = pull,
    control = control, whenAway = whenAway, mirrorTo = mirrorTo,
  }
end

local function normaliseActivity(raw)
  local out = { userIdle = 5, startIdle = 30, lid = true }
  if raw == nil then return out end
  if type(raw) ~= "table" then return fail("activity must be a table") end
  for _, key in ipairs({ "userIdle", "startIdle" }) do
    local v = raw[key]
    if v ~= nil then
      if type(v) ~= "number" or v < 0 then return fail("activity.%s must be a non-negative number", key) end
      out[key] = v
    end
  end
  if raw.lid ~= nil then
    if type(raw.lid) ~= "boolean" then return fail("activity.lid must be a boolean") end
    out.lid = raw.lid
  end
  return out
end

local function checkBackend(backend, options, env)
  if type(backend) == "function" then return true end
  if type(backend) ~= "string" then
    return fail("backend must be a built-in name or a function")
  end
  local builtin = (env.builtinBackends or {})[backend]
  if not builtin then return fail("unknown backend '%s'", backend) end
  local path = options.path or builtin.defaultPath
  if type(path) ~= "string" or not env.fileExists(path) then
    return fail("backend '%s' binary not found at %s", backend, tostring(path))
  end
  return true
end

function Config.validate(raw, env)
  if type(raw) ~= "table" then return fail("configuration must be a table") end

  local secret = raw.secret
  if type(secret) ~= "string" or #secret < MIN_SECRET_LENGTH or secret:find("[^%x]") then
    return fail("secret must be at least %d hex characters", MIN_SECRET_LENGTH)
  end

  if type(raw.displays) ~= "table" or next(raw.displays) == nil then
    return fail("displays is required and must not be empty")
  end
  for id in pairs(raw.displays) do
    if type(id) ~= "string" or id == "" then
      return fail("displays must be a table keyed by non-empty display id strings (got key %s)", tostring(id))
    end
  end
  local displays = {}
  for _, id in ipairs(sortedKeys(raw.displays)) do
    local d, err = normaliseDisplay(id, raw.displays[id])
    if not d then return nil, err end
    displays[id] = d
  end

  local node = raw.node
  if node == nil then node = env.hostname end
  if type(node) ~= "string" or node == "" then return fail("node must be a non-empty string") end
  local known = false
  for _, d in pairs(displays) do
    if d.inputs[node] ~= nil then known = true end
  end
  if not known then return fail("node '%s' does not appear in any display's inputs", node) end

  local backendOptions = raw.backendOptions
  if backendOptions == nil then
    backendOptions = {}
  elseif type(backendOptions) ~= "table" then
    return fail("backendOptions must be a table")
  else
    backendOptions = deepCopy(backendOptions)
  end
  if backendOptions.path ~= nil and type(backendOptions.path) ~= "string" then
    return fail("backendOptions.path must be a string")
  end
  local backend = raw.backend
  if backend == nil then backend = "m1ddc" end
  local ok, err = checkBackend(backend, backendOptions, env)
  if not ok then return nil, err end

  local peers = {}
  if raw.peers ~= nil then
    if type(raw.peers) ~= "table" then return fail("peers must be a list of \"host:port\" strings") end
    for i, entry in ipairs(raw.peers) do
      if not validPeer(entry) then return fail("peers[%d] must be in the form host:port", i) end
      peers[i] = entry
    end
  end

  local port = 8765
  if raw.port ~= nil then
    port = asInteger(raw.port)
    if not port or port < 1 or port > 65535 then return fail("port must be an integer between 1 and 65535") end
  end

  local bonjour = raw.bonjour
  if bonjour == nil then
    bonjour = true
  elseif type(bonjour) ~= "boolean" then
    return fail("bonjour must be a boolean")
  end

  if raw.interface ~= nil and type(raw.interface) ~= "string" then
    return fail("interface must be a string")
  end

  local heartbeat = raw.heartbeat
  if heartbeat == nil then
    heartbeat = 30
  elseif type(heartbeat) ~= "number" or heartbeat <= 0 then
    return fail("heartbeat must be a number greater than 0")
  end

  local logLevel = raw.logLevel
  if logLevel == nil then
    logLevel = "info"
  elseif type(logLevel) ~= "string" then
    return fail("logLevel must be a string")
  end

  local activity, aerr = normaliseActivity(raw.activity)
  if not activity then return nil, aerr end

  return {
    node = node,
    secret = secret,
    backend = backend,
    backendOptions = backendOptions,
    displays = displays,
    port = port,
    peers = peers,
    bonjour = bonjour,
    interface = raw.interface,
    activity = activity,
    heartbeat = heartbeat,
    logLevel = logLevel,
  }
end

return Config
