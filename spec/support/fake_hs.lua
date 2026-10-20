-- Fake `hs` global for specs of init.lua.
--   local fake_hs = dofile("spec/support/fake_hs.lua")
--   local hs, calls = fake_hs.install()          -- minimal: what load/configure/bindHotkeys/generateSecret touch
--   local hs, calls = fake_hs.install({ full = true })  -- adds every module start() needs (see fakes.lua)
--
-- install(opts):
--   opts.hostname       value of hs.host.localizedName() (default "desk-mini")
--   opts.existingFiles  set {path = true} of paths hs.fs.attributes reports as existing
--   opts.full           also install timer, json, hash, screen (+ find, primaryScreen, watcher), window, host, task,
--                       caffeinate, http, httpserver, bonjour
--
-- calls: ordered list of {name, args} records; name is one of "logger.new", "log.d|i|w|e", "log.setLogLevel",
--   "notify.new", "notify.send", "bindHotkeysToSpec". Loading init.lua must not add any entry except logger ones.
--
-- Fake hash/json are not cryptographic: they only have to be deterministic and round-trip safe.

local fakes = dofile("spec/support/fakes.lua")

local M = {}

local function hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function fakeHash()
  local hash = {}
  function hash.new(kind, key)
    local obj = { _kind = kind, _key = key or "", _data = "" }
    function obj.append(self, data) self._data = self._data .. data return self end
    function obj.finish(self) return self end
    function obj.value(self) return hex(self._kind .. ":" .. self._key .. ":" .. self._data) end
    return obj
  end
  return hash
end

-- Encodes by registering the table; decode of an unknown string raises, like a real parser.
local function fakeJson()
  local json, registry = {}, {}
  function json.encode(t)
    registry[#registry + 1] = t
    return "json:" .. #registry
  end
  function json.decode(s)
    local n = type(s) == "string" and s:match("^json:(%d+)$")
    if not n then error("invalid json") end
    return registry[tonumber(n)]
  end
  return json
end

local function addFull(hs)
  hs.timer = fakes.timer()
  function hs.timer.secondsSinceEpoch() return 1700000000 + hs.timer.now() end
  function hs.timer.usleep() end
  hs.json = fakeJson()
  hs.hash = fakeHash()
  hs.host.idleTime = function() return 0 end
  hs.task = fakes.task()
  hs.caffeinate = fakes.caffeinate()
  hs.http = fakes.http()
  hs.httpserver = fakes.httpserver()
  hs.bonjour = fakes.bonjour()
  hs.screen = {
    watcher = fakes.screenWatcher(),
    screens = {},
    allScreens = function() return hs.screen.screens end,
    primaryScreen = function() return hs.screen.screens[1] end,
    find = function(uuid)
      for _, s in ipairs(hs.screen.screens) do
        if s:getUUID() == uuid then return s end
      end
      return nil
    end,
  }
  hs.window = { allWindows = function() return {} end }
end

function M.install(opts)
  opts = opts or {}
  local calls = {}
  local function record(name, ...) calls[#calls + 1] = { name = name, args = { ... } } end

  local existing = opts.existingFiles or {}
  local hs = {
    host = { localizedName = function() return opts.hostname or "desk-mini" end },
    fs = { attributes = function(path) if existing[path] then return { mode = "file" } end end },
    notify = {
      new = function(spec)
        record("notify.new", spec)
        return { send = function(self) record("notify.send", spec) return self end }
      end,
    },
    logger = {
      new = function(name, level)
        record("logger.new", name, level)
        local log = { name = name, level = level, messages = {} }
        for _, lvl in ipairs({ "d", "i", "w", "e" }) do
          log[lvl] = function(msg)
            log.messages[#log.messages + 1] = { lvl, msg }
            record("log." .. lvl, msg)
          end
        end
        log.setLogLevel = function(l) log.level = l record("log.setLogLevel", l) end
        return log
      end,
    },
    spoons = {
      resourcePath = function(f) return f end,
      bindHotkeysToSpec = function(spec, mapping) record("bindHotkeysToSpec", spec, mapping) end,
    },
  }
  if opts.full then addFull(hs) end
  _G.hs = hs
  return hs, calls
end

function M.uninstall()
  _G.hs = nil
end

return M
