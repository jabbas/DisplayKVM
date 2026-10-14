# DisplayKVM

A [Hammerspoon](https://www.hammerspoon.org) Spoon that hands your external monitors from one Mac to another
automatically, like a software KVM.

When you unlock or wake a Mac, it takes the monitors. When you lock it, put it to sleep or close its lid, it gives
them to the Mac you used most recently, or back to the monitor's *home* Mac if nobody else is active. The input is
switched over DDC/CI, so no hardware switch is needed. The Macs talk to each other directly over the LAN (found
with Bonjour, or a static list), and every message is signed with a shared secret. There is no server and no
leader: any Mac can be off at any time.

## Requirements

- macOS with [Hammerspoon](https://www.hammerspoon.org) on every Mac in the group.
- A monitor that accepts DDC/CI input switching and has one input per Mac.
- A DDC command-line backend on every Mac: [`m1ddc`](https://github.com/waydabber/m1ddc) (Apple silicon, the
  default), [`ddcctl`](https://github.com/kfix/ddcctl), BetterDisplay's `betterdisplaycli`, or Lunar. You can also
  supply your own function.
- Macs on the same LAN with roughly synchronised clocks (NTP, the macOS default).
- **macOS permissions.** Hammerspoon needs the **Local Network** permission (System Settings → Privacy & Security →
  Local Network → Hammerspoon) for Bonjour discovery and for talking to the other Macs over the LAN; macOS asks the
  first time DisplayKVM starts. If the macOS application firewall is on and asks whether Hammerspoon may accept
  incoming connections, allow it, otherwise the other Macs cannot reach this one.

## Installation

**With git** (works on every Mac, no build step):

```sh
git clone https://github.com/jabbas/DisplayKVM ~/.hammerspoon/Spoons/DisplayKVM.spoon
```

**With [SpoonInstall](https://www.hammerspoon.org/Spoons/SpoonInstall.html).** The Spoon lives at the root of the
`main` branch, so the release workflow publishes a ready-made zip and `docs/docs.json` to the `dist` branch.
SpoonInstall supports a `branch` field for a repository:

```lua
hs.loadSpoon("SpoonInstall")
spoon.SpoonInstall.repos.DisplayKVM = {
  url = "https://github.com/jabbas/DisplayKVM",
  desc = "DisplayKVM Spoon repository",
  branch = "dist",
}
spoon.SpoonInstall:andUse("DisplayKVM", {
  repo = "DisplayKVM",
  fn = function(s)
    s:configure({
      -- the configuration from the section below
    })
    s:start()
    s:bindHotkeys({ claim = { { "ctrl", "alt", "cmd" }, "M" }, release = { { "ctrl", "alt", "cmd" }, "R" } })
  end,
})
```

`andUse` installs a missing Spoon **asynchronously**, so on the first run `spoon.DisplayKVM` does not exist yet when
`andUse` returns. Configure and start the Spoon inside `fn`, which runs once it is installed and loaded; do not call
`spoon.DisplayKVM:configure(...)` on the line after `andUse`. Alternatively, set
`spoon.SpoonInstall.use_syncinstall = true` before calling `andUse`, which makes it install synchronously (and then
`spoon.DisplayKVM:configure(...)` right after `andUse` works). If your SpoonInstall is too old to know `branch`, download
`https://github.com/jabbas/DisplayKVM/raw/dist/Spoons/DisplayKVM.spoon.zip` (also attached to each GitHub release),
unzip it and open `DisplayKVM.spoon`.

## Configuration

The configuration is **identical on every Mac**. Only `node` (and how the secret is supplied) differs.

```lua
hs.loadSpoon("DisplayKVM")
spoon.DisplayKVM:configure({
  node    = "desk-mini",                -- this Mac's name; set it explicitly
  secret  = "<64 hex characters>",      -- shared by the group; keep it out of git
  backend = "m1ddc",
  displays = {
    left = {
      match  = { ["desk-mini"] = "<UUID as seen from desk-mini>", laptop = "<UUID as seen from laptop>" },
      inputs = { ["desk-mini"] = 15, laptop = 16 },
      home   = "desk-mini",
    },
  },
})
spoon.DisplayKVM:start()
spoon.DisplayKVM:bindHotkeys({                                                  -- optional
  claim   = { { "ctrl", "alt", "cmd" }, "M" },   -- take the monitors now
  release = { { "ctrl", "alt", "cmd" }, "R" },   -- hand them to another Mac
})
```

If `match` is a table it needs an entry for **every** node listed in `inputs`; `configure()` rejects a missing one.
A plain string (a name substring or one UUID) is used on every node.

Find a screen's name and UUID in the Hammerspoon console:

```lua
for _, s in ipairs(hs.screen.allScreens()) do print(s:name(), s:getUUID()) end
```

Find the DDC input numbers for your monitor's ports with your backend (for example `m1ddc display list`, and
the monitor's documentation). Common values are 15/16 (DisplayPort 1/2) and 17/18 (HDMI 1/2).

| Field | Required | Default | Meaning |
|---|---|---|---|
| `node` | no | `hs.host.localizedName()` | Node name. Must appear in at least one `inputs`. |
| `secret` | yes | — | 64 hex characters (32 random bytes). |
| `backend` | no | `"m1ddc"` | `"m1ddc"`, `"ddcctl"`, `"betterdisplay"`, `"lunar"`, or a function `(display, input, done)` that calls `done(true)` or `done(false)` **before it returns** (see [Backends](#backends)). |
| `backendOptions` | no | — | Backend settings, for example `{ path = "/opt/homebrew/bin/m1ddc" }`, `{ index = 2 }` (ddcctl) or `{ inputAlt = true }` (BetterDisplay). |
| `displays.<id>.match` | yes | — | A string is matched on every node: a UUID is compared with the screen UUID (case-insensitive), anything else is a plain substring of the screen name (not a Lua pattern). A table `{ node = UUID or substring }` disambiguates identical monitors or different UUIDs per node. |
| `displays.<id>.inputs` | yes | — | `{ node = DDC input }`. A node without an entry does not take part in that display. |
| `displays.<id>.home` | no | first node in `inputs` | Release target when no other node is active. |
| `displays.<id>.pull` | no | `true` | Set `false` for monitors that ignore DDC while showing another input. Claims then always ask the current owner to push. |
| `port` | no | `8765` | Server port. |
| `peers` | no | — | Static list of `"host:port"`, in addition to Bonjour. |
| `bonjour` | no | `true` | `false` disables discovery (static peers only). |
| `interface` | no | — | Bind the HTTP server to one network interface. |
| `activity` | no | `{ userIdle = 5, startIdle = 30, lid = true }` | Thresholds. Use `lid = false` for desktops and clamshell users. |
| `heartbeat` | no | `30` | Seconds between state heartbeats. A node is absent after 3 silent intervals. |
| `logLevel` | no | `"info"` | Level of the `DisplayKVM` logger. |

`configure()` validates the configuration (the node appears in some `inputs`, `home` has an input, the secret is
long enough, the binary of a built-in backend exists). On an error it logs, shows a notification, and `start()`
does nothing.

### The secret

Generate one secret and use the same value on every Mac:

```lua
hs.loadSpoon("DisplayKVM")
print(spoon.DisplayKVM.generateSecret())
```

Never commit it. Load it from a file outside your dotfiles repository (or from the Keychain), for example:

```lua
local f = assert(io.open(os.getenv("HOME") .. "/.config/displaykvm/secret", "r"))
local secret = f:read("l")
f:close()
```

Messages are authenticated with HMAC-SHA256 but **not encrypted**, so DisplayKVM is meant for a trusted LAN only.

### Backends

| Backend | How it addresses the display | Notes |
|---|---|---|
| `m1ddc` | Screen UUID | Default path `/opt/homebrew/bin/m1ddc`. |
| `ddcctl` | **1-based index of the external display** | It cannot use a UUID or a name. Set `backendOptions.index` (default `1`) to the display's position among your *external* displays; the built-in screen is not counted. |
| `betterdisplay` | Screen UUID | Uses `betterdisplaycli` (BetterDisplay must be running). `backendOptions.inputAlt = true` (alternate DDC addressing, for some LG monitors) is **untested**. |
| `lunar` | Screen **name** | Lunar cannot address a display by UUID, so `target.name` is passed and Lunar fuzzy-matches it. The default path is the app binary, `/Applications/Lunar.app/Contents/MacOS/Lunar`; set `backendOptions.path` to use another one. Lunar's LG-specific input codes are **untested**: use the raw DDC value. |
| function | whatever you want | `function(display, input, done) ... done(true) end`. `display` is `{ id, uuid, name }`. See the note below. |

Set `backendOptions.path` if your binary is somewhere else.

**A function backend must call `done` before it returns.** Answering a request from another Mac and handing the
monitors over when your Mac goes to sleep both switch *synchronously*: they cannot wait for a callback, and a `done`
that has not been called by the time the function returns is treated as a failed switch (DisplayKVM logs a warning
once). Only the claim path on your own Mac copes with a `done` that is called later. So do the work synchronously
(for example with `hs.execute`) and then call `done(ok)`, or use one of the built-in backends, which are designed
for both paths:

```lua
backend = function(display, input, done)
  local _, ok = hs.execute(string.format("/opt/homebrew/bin/m1ddc display %s set input %d", display.uuid, input))
  done(ok == true)
end,
```

## How it works

Every Mac replicates a small state with last-writer-wins registers: who owns which display, and which Macs are
active. When a Mac becomes active (unlock, wake, start, or the `claim` hotkey) it switches each of its displays to
its own input: directly if it still sees the display (*pull*), otherwise by asking the current owner to push.
When it becomes inactive (lock, sleep, lid closed) it gives each display to the most recently active other Mac, or
to the display's `home` if no other Mac is active, or keeps it if it already is the home.
Giving a display to `home` does not require the home Mac to be awake; the next claim repairs the state.

The full design, protocol and edge cases are in [docs/design.md](https://github.com/jabbas/DisplayKVM/blob/main/docs/design.md).

## Limitations

- Always-visible displays cannot be verified after a switch: if a monitor stays in `hs.screen.allScreens()` when
  it shows another input, DisplayKVM cannot tell whether a switch worked.
- DDC from a Mac whose input is not active is firmware-dependent; some monitors ignore it (use `pull = false`).
- Clocks must be NTP-synchronised (messages older than 30 s are rejected).
- LAN only, and macOS only.
- No encryption, only authentication. No keyboard, mouse or USB sharing.

## Troubleshooting

- **See what the node thinks:** `hs.inspect(spoon.DisplayKVM:status())` in the Hammerspoon console returns
  `{ node, instance, peers, displays }`:
  - `peers[name] = { lastSeen, active, alive }`: `lastSeen` is the time (epoch milliseconds) of the last verified
    message from that Mac, or `nil` if there was none yet; `active` is that Mac's replicated presence (`false` when
    it is inactive, `nil` when nothing is known about it); `alive` is true if it was heard from within the last
    3 heartbeat intervals.
  - `displays[id] = { owner, visible, input }`: `owner` is the Mac the state says has the display (`nil` if unknown);
    `visible` is whether *this* Mac currently sees the monitor; `input` is this Mac's DDC input for it.
- **Logs:** the logger is named `DisplayKVM`. Raise detail with `logLevel = "debug"` in `configure`.
- **The monitor flips back by itself:** disable the monitor's automatic input selection in its OSD menu.
- **Clamshell mode** (laptop closed with an external display): set `activity.lid = false`, otherwise closing the
  lid releases the displays.
- **The monitor ignores a claim** while showing another input: set `pull = false` on that display.
- **No peers found** (`status()` shows no peers, or `dns-sd -B _displaykvm._tcp` on another Mac shows nothing from
  this one): first check that Hammerspoon has the **Local Network** permission (System Settings → Privacy &
  Security → Local Network) on every Mac, and that the firewall allows incoming connections for Hammerspoon.
  Then, for VLANs and corporate networks without mDNS, set `bonjour = false` and list the other Macs in `peers`.
- **"cannot listen on port ..." notification:** another program (or an old Hammerspoon instance) holds the port;
  change `port` on every Mac.
- **"clock skew" or 401 in the logs:** enable network time on all Macs, and check that the secret is identical.
- **Two Macs with the same `node`:** you get a notification; give each Mac its own name.

## Development

The decision logic is pure Lua and runs without Hammerspoon. You need Lua 5.4 and the LuaRocks packages `busted`,
`luacheck` and `dkjson`:

```sh
luarocks install busted && luarocks install luacheck && luarocks install dkjson
luacheck . && busted
```

`tools/build-dist.sh <out-dir>` builds the release zip and `docs.json`. Pushing a tag `X.Y.Z` (no `v`
prefix; it must equal `obj.version`) runs the release workflow, which publishes both to the `dist` branch and
attaches the zip to a GitHub release. Release 0.1.0 was tagged `v0.1.0`, before this scheme. See
[CHANGELOG.md](CHANGELOG.md) for what changed.

## License

MIT, see [LICENSE](LICENSE).
