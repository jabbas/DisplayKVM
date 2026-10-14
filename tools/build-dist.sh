#!/usr/bin/env bash
# Builds the release artifacts into <out-dir>:
#   DisplayKVM.spoon.zip  the Spoon (DisplayKVM.spoon/ at the top level of the archive)
#   docs.json             SpoonInstall metadata (see tools/gen-docs-json.lua)
# Usage: tools/build-dist.sh <out-dir>      (set LUA to pick the Lua interpreter, default "lua")
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <out-dir>" >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$1"
out="$(cd "$1" && pwd)"
lua_bin="${LUA:-lua}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

spoon="$work/DisplayKVM.spoon"
mkdir -p "$spoon/backends"
cp "$root"/*.lua "$spoon/"
cp "$root"/backends/*.lua "$spoon/backends/"
cp "$root/LICENSE" "$root/README.md" "$root/CHANGELOG.md" "$spoon/"

rm -f "$out/DisplayKVM.spoon.zip"
(cd "$work" && zip -q -X -r "$out/DisplayKVM.spoon.zip" DisplayKVM.spoon)

"$lua_bin" "$root/tools/gen-docs-json.lua" "$root/init.lua" > "$out/docs.json"

echo "built $out/DisplayKVM.spoon.zip and $out/docs.json"
