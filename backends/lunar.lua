-- Lunar CLI: https://lunar.fyi/ (Command-Line Integration; `lunar displays <display> <property> <value>`,
-- changelog examples: `lunar displays ultrafine input hdmi`, `lunar displays lg input lgHdmi1`) and the CLI
-- source https://github.com/alin23/Lunar/blob/master/Lunar/Data/CLI.swift (Displays command).
-- Lunar cannot address a display by UUID: the <display> argument is a serial, a CoreGraphics id or a
-- (fuzzy-matched) name, so this backend passes `target.name`. The `input` property accepts a raw DDC value
-- as well as a name, so the configured number is passed as is.
-- defaultPath is the app binary documented for `install-cli`
-- (/Applications/Lunar.app/Contents/MacOS/Lunar), which also runs CLI commands. The `lunar` shim location
-- is not documented; set backendOptions.path to use it.
-- UNVERIFIED: Lunar-specific LG codes (opts.inputAlt) are not supported; use the raw DDC value instead.
return {
  name = "lunar",
  defaultPath = "/Applications/Lunar.app/Contents/MacOS/Lunar",
  args = function(target, input, _)
    return { "displays", target.name, "input", tostring(input) }
  end,
}
