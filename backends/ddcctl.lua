-- ddcctl: https://github.com/kfix/ddcctl (README "Input Sources": `ddcctl -d 1 -i 17`;
-- usage text in src/ddcctl.m: `-d <1-..> [display#]`, `-i <1-18> [select input source]`).
-- ddcctl cannot address a display by UUID or name: -d is the 1-based index of the attached
-- external displays (built-in screens are skipped), in NSScreen order. The index therefore comes
-- from backendOptions.index (default 1) instead of from `target`. It has no alternate input codes,
-- so opts.inputAlt is ignored.
return {
  name = "ddcctl",
  defaultPath = "/opt/homebrew/bin/ddcctl",
  args = function(_, input, opts)
    return { "-d", tostring(opts.index or 1), "-i", tostring(input) }
  end,
}
