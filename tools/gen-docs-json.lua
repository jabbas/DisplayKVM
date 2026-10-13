-- Generates the minimal `docs/docs.json` that SpoonInstall expects, from the header of init.lua.
--
-- Usage:  lua tools/gen-docs-json.lua [path/to/init.lua] > docs.json   (default: init.lua)
--
-- Findings (checked 2026-10-13):
--
-- SpoonInstall (https://github.com/Hammerspoon/Spoons/blob/master/Source/SpoonInstall.spoon/init.lua)
--   * Registered repos have the fields `desc`, `branch` and `url`; `branch` IS supported and defaults to
--     "master" (see `_build_repo_urls`, lines ~98-104).
--   * It builds  <url>/raw/<branch>/docs/docs.json  for the metadata and
--     <url>/raw/<branch>/Spoons/  as the download base, so the zip must be at
--     Spoons/<name>.spoon.zip  (`download_url = download_base_url .. v.name .. ".spoon.zip"`,
--     `_storeRepoJSON`, line ~83). `url` must be the plain GitHub repo URL (a trailing "/" is stripped).
--   * docs.json must be a JSON array of objects. SpoonInstall itself reads only `name` (the key and the zip
--     file name) and `desc` (shown by `search`). The official generator (hs.doc.builder.genJSON) emits many
--     more fields; this tool writes the useful metadata fields: name, version, desc, author, license, homepage.
--   * Because `branch` is supported, no full-URL workaround is needed. A full `url` pointing at the dist
--     branch would NOT work, as "/raw/<branch>/..." is always appended. A SpoonInstall too old to know
--     `branch` would look at "master", so there the zip must be installed by hand from
--     https://github.com/jabbas/DisplayKVM/raw/dist/Spoons/DisplayKVM.spoon.zip (the README says so).
--
-- GitHub Actions (latest stable majors, via the GitHub releases API):
--   * leafo/gh-actions-lua       v13  https://github.com/leafo/gh-actions-lua/releases  (node24; default
--                                     luaVersion is 5.5, so "5.4" must be passed explicitly)
--   * leafo/gh-actions-luarocks  v6   https://github.com/leafo/gh-actions-luarocks/releases
--   * softprops/action-gh-release v3  https://github.com/softprops/action-gh-release/releases  (v2 uses the
--                                     deprecated Node 20 runtime)
--   * actions/checkout           v7   https://github.com/actions/checkout/releases

local M = {}

local function jsonString(s)
  local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

-- First paragraph after the `--- === Name ===` line of the module header, joined into one line.
local function description(src)
  local parts, inHeader = {}, false
  for line in (src .. "\n"):gmatch("(.-)\r?\n") do
    local text = line:match("^%-%-%-%s?(.*)$")
    if not inHeader then
      if text and text:match("^===%s*.-%s*===$") then inHeader = true end
    else
      if text == nil or text:match("^%s*$") then
        if #parts > 0 or text == nil then break end
      else
        parts[#parts + 1] = text
      end
    end
  end
  return table.concat(parts, " ")
end

-- Returns the docs.json text for the Spoon source `src` (the contents of init.lua).
function M.generate(src)
  local meta = {}
  for key, value in src:gmatch('\nobj%.(%w+)%s*=%s*"([^"\n]*)"') do
    meta[key] = value
  end
  assert(meta.name, "init.lua does not set obj.name")
  assert(meta.version, "init.lua does not set obj.version")
  local fields = {
    { "name", meta.name },
    { "version", meta.version },
    { "desc", description(src) },
    { "author", meta.author or "" },
    { "license", meta.license or "" },
    { "homepage", meta.homepage or "" },
  }
  local out = {}
  for _, f in ipairs(fields) do
    out[#out + 1] = "    " .. jsonString(f[1]) .. ": " .. jsonString(f[2])
  end
  return "[\n  {\n" .. table.concat(out, ",\n") .. "\n  }\n]\n"
end

if arg and arg[0] and arg[0]:match("gen%-docs%-json%.lua$") then
  local path = arg[1] or "init.lua"
  local f = assert(io.open(path, "rb"))
  local src = f:read("a")
  f:close()
  io.write(M.generate(src))
end

return M
