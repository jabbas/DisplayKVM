std = "lua54"
max_line_length = 120
exclude_files = {".luarocks"}

-- Modules that talk to Hammerspoon may read the global `hs`.
local uses_hs = {
  "init.lua", "runner.lua", "display.lua", "transport.lua", "discovery.lua",
  "activity.lua", "lid.lua", "node.lua", "backends/*.lua",
}
for _, f in ipairs(uses_hs) do
  files[f] = { read_globals = { "hs" } }
end

-- Pure modules (state.lua, policy.lua, config.lua, message.lua) get no `hs`:
-- any access to the global `hs` is reported as an error.

-- Specs may read and set the global `hs` (fake harness).
files["spec/**"] = { std = "+busted", globals = { "hs" } }
