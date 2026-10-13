-- BetterDisplay CLI: https://github.com/waydabber/betterdisplaycli
-- Syntax from "Integration features, CLI" (https://github.com/waydabber/BetterDisplay/wiki/Integration-features,-CLI)
-- and https://betterdisplay.pro/guide/integration/cli-reference/ :
--   betterdisplaycli set --UUID=<display uuid> --feature=ddc --vcp=inputSelect --value=<input>
-- `--UUID` identifies the display by its macOS UUID; `ddc` + `vcp` sends a raw DDC write (VCP
-- `inputSelect`, 0x60). BetterDisplay must be running.
-- UNVERIFIED: opts.inputAlt (`--feature=ddcAlt --vcp=inputSelectAlt`, "alternate addressing, mostly used by
-- some LG displays to control input source") follows the reference text but has not been run on hardware.
return {
  name = "betterdisplay",
  defaultPath = "/opt/homebrew/bin/betterdisplaycli",
  args = function(target, input, opts)
    local alt = opts.inputAlt == true
    return {
      "set",
      "--UUID=" .. target.uuid,
      alt and "--feature=ddcAlt" or "--feature=ddc",
      alt and "--vcp=inputSelectAlt" or "--vcp=inputSelect",
      "--value=" .. tostring(input),
    }
  end,
}
