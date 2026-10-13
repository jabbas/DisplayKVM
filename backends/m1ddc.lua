-- m1ddc: https://github.com/waydabber/m1ddc
-- `m1ddc display <uuid> set input <value>` addresses the display by its macOS UUID.
-- m1ddc has no alternate input codes, so opts.inputAlt is ignored.
return {
  name = "m1ddc",
  defaultPath = "/opt/homebrew/bin/m1ddc",
  args = function(target, input, _)
    return { "display", target.uuid, "set", "input", tostring(input) }
  end,
}
