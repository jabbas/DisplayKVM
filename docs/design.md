# DisplayKVM — design

- **Status:** Approved, 2026-10-12
- **Scope:** a Hammerspoon Spoon that shares M external monitors between N Macs

## 1. Summary

DisplayKVM is a [Hammerspoon](https://www.hammerspoon.org) Spoon that hands one or more external monitors from one Mac to another automatically. When you unlock or wake a Mac, it takes the monitors. When you lock it, put it to sleep or close its lid, it gives them to the Mac you used most recently, or back to the monitor's home Mac if nobody else is active.

The monitor input is switched over DDC/CI, using a pluggable command-line backend (`m1ddc`, `ddcctl`, BetterDisplay, Lunar or a user function). The Macs coordinate as equals over the LAN. They discover each other with Bonjour and replicate a small amount of state (who owns which display, who is active) with last-writer-wins registers. Every message is signed with a shared secret.

There is no central server and no leader election. Every Mac runs the same code and the same configuration. Only the node name differs.

## 2. Context and problem

### 2.1 The problem

A person with several Macs (for example a desktop and a laptop) and one or more monitors, each with several inputs, has to switch the monitor input by hand with the monitor's OSD buttons or a hotkey. The wish is to make that follow the person: sit down at a Mac and the monitor shows that Mac.

### 2.2 Prior art and the gap

| Tool | What it does | What it lacks |
|---|---|---|
| `display-switch` | Switches input when a USB device is attached to or removed from the machine | One-way, per machine; no ownership tracking across machines; USB-triggered only |
| Lunar, BetterDisplay | Manual input switching, CLI | No lock/unlock/wake/lid triggers; no coordination between Macs |
| `m1ddc`, `ddcctl` | CLI backends that send DDC commands | Only a transport for the command, no policy |
| Hotkey scripts | One hotkey, one command | Manual; no state |

No Hammerspoon Spoon touches DDC. The gap is twofold: reacting to lock, unlock, wake, sleep and lid events, and keeping a consistent view of which Mac owns which monitor across several machines.

### 2.3 Hardware constraints

These drive several decisions below:

- **DDC from a Mac whose input is not active is firmware-dependent.** Some monitors accept the command, some ignore it. A Mac that wants a monitor currently showing another input can therefore not always *pull* it. The alternative is to ask the current owner to *push* the monitor away.
- **Reading the current input (`get input`) is unreliable** on many monitors, and some (LG, for example) need alternate input codes. DisplayKVM never relies on reading the input. It tracks ownership in its own state.
- **A monitor may or may not stay listed in `hs.screen.allScreens()`** after it switches to another input. Whether it does is monitor-dependent and must be checked on the real hardware. This decides whether a Mac can tell that it can see a display (`visible()`), and so whether it can pull.

## 3. Goals and non-goals

### 3.1 Goals

- N Macs × M shared monitors, macOS and Hammerspoon only.
- Automatic hand-over on lock, unlock, wake, sleep and lid events.
- Release to the most recently active other Mac, else to the monitor's home.
- Identical configuration on every Mac. Only `node` (and how the secret is supplied) differs.
- No central arbiter: any Mac can be off at any time.
- Pluggable DDC backend.
- Decision logic that is pure Lua and testable without Hammerspoon.
- Distribution as a normal Spoon.

### 3.2 Non-goals

- Non-macOS peers.
- Operation across the WAN or the internet. DisplayKVM is LAN-only by design.
- Encryption of messages. They are authenticated, not confidential (§8).
- Hardware KVM features: USB hub switching, EDID emulation, audio routing.
- Keyboard and mouse sharing. Use a separate tool for that.

## 4. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Peer-to-peer; every Mac is equal; discovery with Bonjour; static peer list as fallback.** | A KVM-like setup must keep working when any one Mac is off. A fixed arbiter would be a single point of failure. A leader election is far more complex than the problem needs. Bonjour needs no addresses in the configuration; the static list covers networks without mDNS. |
| D2 | **Replicated last-writer-wins (LWW) state** (variant A). | Small state, trivially mergeable, repairable by the next event. Supports "most recently active" as a first-class query. |
| D3 | **Release goes to the most recently active other node; if none is active, to the display's home; if the owner is the home and nobody else is active, keep it.** | Matches how people work: after locking one Mac you usually move to the Mac you used before. Home gives a deterministic resting place. |
| D4 | **Packaged as a Spoon**, with decision logic in pure Lua and thin `hs.*` adapters. | Fits the Hammerspoon ecosystem (SpoonInstall, `hs.loadSpoon`). Pure logic runs under `busted` without stubs. |
| D5 | **The repository root is the Spoon.** | The repo can be cloned straight into `Spoons/DisplayKVM.spoon`, with no build step for users who prefer git. |
| D6 | **Object-oriented Lua with metatables**; one long-lived `Node` object holds all watchers, timers and the server as fields. | No globals, nothing to be garbage-collected by accident. |

### 4.1 Rejected architecture variants

- **B — elected leader.** One Mac arbitrates, the others ask. Rejected as too complex: it needs leader election, failover and split-brain handling, all for a state that is a handful of records.
- **C — stateless broadcast.** Every event is broadcast and nobody keeps state. Rejected because it cannot answer "who was most recently active?" (D3), and a Mac that starts later cannot learn who owns a display.

## 5. Architecture

Principle: **decision logic is pure Lua with no `hs.*` calls**, so it can be unit-tested with `busted` without stubs. Everything that touches the system is a thin adapter.

| Object | Responsibility | Depends on |
|---|---|---|
| `obj` (`init.lua`) | Public Spoon API: `configure(cfg)`, `start()`, `stop()`, `bindHotkeys(map)`, manual `claim(displayId?)`, `release()`, `status()`, and `DisplayKVM.generateSecret()`. Does no work at load time. | Node |
| `Node` | Orchestrates: sensor events → Policy decisions → Display/Transport actions, and merges peer state. The only long-lived object (held by `spoon.DisplayKVM`). | all below |
| `State` (pure) | LWW registers `owner[display] = {node, ts}` and `presence[node] = {active, since, ts}`. `merge(remote)`, serialize/deserialize, deterministic tie-break (ts, then node name). | none |
| `Policy` (pure) | `onActive(state, cfg, me)` returns every display this node has an input for, regardless of the recorded owner: a claim always switches, because the recorded owner may be stale (the monitor may have changed input on its own, or the node was reloaded). `onInactive(state, cfg, me, alive)` returns, for each owned display, a release target: the most recently active other node that is alive and has an input for that display, else home (if home is not this node), else keep. Input is state and config, output is an action list. | none |
| `Config` (pure) | Validates and normalises the user configuration, fills defaults. | none |
| `Message` (pure) | Builds and verifies signed envelopes: HMAC, timestamp window, nonce cache. HMAC, clock, randomness and JSON codec are injected. | none |
| `Runner` | Runs a command through `hs.task` with a timeout, asynchronously or synchronously. | hs.task, hs.timer |
| `ActivitySensor` | Turns `hs.caffeinate.watcher`, idle time and lock state into `active` / `inactive` events. See below. | hs.caffeinate, hs.host |
| `LidSensor` | Reads the lid state with `ioreg -r -k AppleClamshellState -d 1`, run asynchronously, debounced by 1.5 s on `hs.screen.watcher`. Lid closed → inactive. Lid open and unlocked → active. Lid open and locked → wait for unlock. No-op on machines without a lid; disabled by `activity.lid = false`. | hs.screen.watcher, hs.task |
| `Display` | One configured monitor: match (UUID or name pattern, per node or global), inputs map node → DDC input, home, `pull` flag, backend options. Methods: `visible()`, `switchTo(node, done)` with retry. | Backend |
| `Backend` | Common interface `setInput(display, input, done)`, always asynchronous through `hs.task` with a 5 s timeout. A synchronous variant (`waitUntilExit`, 2 s) is used only on `systemWillSleep`. Built-ins: `m1ddc`, `ddcctl`, `betterdisplay` (`betterdisplaycli`), `lunar`; or a user function `(display, input, done)`. | hs.task |
| `Transport` | `hs.httpserver` serving `POST /v1/msg`, plus a client (`hs.http.asyncPost`). HMAC-SHA256 sign and verify; rejects stale and replayed messages. | hs.httpserver, hs.http, hs.hash |
| `Discovery` | Publishes this node's Bonjour service, browses peers' services, merges in the static `peers` list. | hs.bonjour |

`ActivitySensor` rules:

- Unlock → `active`.
- `screensDidWake` / `systemDidWake` while unlocked and idle time < `userIdle` (5 s) → `active`.
- `screensDidLock` / `screensDidSleep` / `systemWillSleep` → `inactive`.
- At start: unlocked and idle time < `startIdle` (30 s) → `active`; otherwise `inactive` with no action.

Files: `init.lua`, `node.lua`, `state.lua`, `policy.lua`, `config.lua`, `message.lua`, `activity.lua`, `lid.lua`, `runner.lua`, `display.lua`, `transport.lua`, `discovery.lua`, `backends/*.lua`. The logger name is `DisplayKVM`.

```d2
direction: right
spoon: DisplayKVM.spoon {
  api: "init.lua (obj)\nconfigure / start / stop\nbindHotkeys / claim / release / status"
  node: "Node\norchestration"
  pure: "Pure logic (no hs.*)" {
    state: "State\nLWW: display owners,\nnode presence"
    policy: "Policy\nwho claims, whom to release to"
  }
  adapters: "Adapters (hs.*)" {
    activity: "ActivitySensor\nlock, wake, idle"
    lid: "LidSensor\nlid + debounce"
    display: "Display\nmatch, visible()"
    backend: "Backend\nm1ddc | ddcctl | betterdisplay | lunar\n(hs.task, async, timeout)"
    transport: "Transport\nHTTP server + client, HMAC"
    discovery: "Discovery\nBonjour (+ static list)"
  }
  api -> node
  node -> pure.state
  node -> pure.policy
  adapters.activity -> node: "active / inactive"
  adapters.lid -> node: "lid open / closed"
  node -> adapters.display
  adapters.display -> adapters.backend: "setInput"
  node <-> adapters.transport: "messages"
  adapters.discovery -> adapters.transport: "peer list"
}
peers: "Other Macs running DisplayKVM" {shape: cylinder}
spoon.adapters.transport <-> peers: "HTTP + JSON + HMAC (LAN)"
```

Spoon conventions followed: `init.lua` returns `obj` with `name`, `version`, `author`, `license` and `homepage`; methods `init`, `start`, `stop`, `bindHotkeys`; no work at load time. `require` does not work inside a Spoon, so modules are loaded with `dofile(hs.spoons.resourcePath("x.lua"))`.

## 6. Replicated state and merge rules

| Record | Fields | Written by |
|---|---|---|
| `presence[node]` | `active` (bool), `since` (ts), `ts` | only the node itself |
| `owner[display]` | `node`, `ts` | the claimer (`owner = self`) or the releaser (`owner = target`) |

**Merge:** for each record, the higher `ts` wins. On equal `ts`, an `owner` record with the higher node name wins; a `presence` record keeps the existing value (it has a single writer, so equal `ts` means the same record). This makes merge idempotent, commutative and associative, so peers converge regardless of delivery order or duplication.

**Writer rule:** a node writes its own `presence` with `ts = max(now, previous ts + 1)`, so two writes within the same millisecond (for example active → inactive on a fast lock) cannot collide. `since` changes only on an active/inactive transition; heartbeats resend the record unchanged.

**Local liveness (not replicated):** `lastSeen[node]` is the last time any verified message — a request to this node's server or a signed reply to this node's own request — was received from that node. A node silent for 3 heartbeat intervals is considered absent and is not a release candidate. Its `presence` record is kept but ignored by Policy.

Because every record has a single logical writer, and conflicting `owner` writes are resolved deterministically, the state is always repairable by the next event.

## 7. Protocol

### 7.1 Transport and envelope

Messages are `POST /v1/msg` with a JSON body and the header `X-DisplayKVM-Sig: hex(HMAC-SHA256(secret, raw_body))`.

```json
{ "v": 1, "from": "<node>", "instance": "<random per start>", "ts": 1760000000000,
  "nonce": "<random hex>", "type": "...", "body": { } }
```

- `ts` is Unix time in milliseconds.
- `instance` is random per start and lets peers detect two nodes with the same name.

### 7.2 Message types

| type | When | Body / reply |
|---|---|---|
| `hello` | On start and when a new peer is discovered | The sender's full state. The reply is the receiver's full state (two-way sync). |
| `state` | After every local change and every `heartbeat` seconds (default 30) | Changed records or full state. Reply 204. |
| `request` | A claim when pulling is not possible | `{display, to}` sent to the owner. The owner pushes. Reply `ok` or `failed`. |

### 7.3 Validation

The receiver checks, in order:

1. The signature, with a constant-time compare.
2. `|now − ts| ≤ 30 s`.
3. The nonce has not been seen within the window.
4. `from` is not the receiver itself.

Any failure returns 401 with no details.

### 7.4 Claim flow

- If the display is visible locally and `pull ~= false`, switch locally (**pull**).
- Otherwise send `request` to the recorded owner if it is alive and not this node; if there is no usable owner, or the owner is unreachable or replies `failed`, broadcast `request` to every alive peer. Whoever sees the display pushes; the first `ok` wins.
- The pusher writes `owner = <requester>` after its switch succeeded and broadcasts it. The requester writes `owner = self` after `ok` (or after its own pull succeeded). Both records name the same node, so LWW merges them cleanly even if the reply is lost.
- Each attempt — pull, request, broadcast, or a failed post-switch verification — counts towards the limit of 5 attempts per claim (§10).

### 7.5 Release flow

The owner always sees the display, because it is showing the owner's input, so a push is reliable. The target is chosen by Policy (D3). Releasing to `home` does **not** require home to be alive: if home is off or asleep, the monitor shows "no signal" until someone claims it. This is deliberate — it matches the simple "give it back" behaviour people expect, and the next claim repairs the state.

On `systemWillSleep` both the switch and the state broadcast are synchronous (`hs.http.doRequest`, 1 s per peer), because asynchronous work does not complete before the machine sleeps.

```d2
shape: sequence_diagram
b: Node B (becomes active)
a: Node A (owner)
mon: Monitor
b -> a: "state: presence[B]=active"
b -> b: "display visible? → pull: setInput(input[B])"
b -> a: "(if pull impossible) request {display, to: B}"
a -> mon: "push: setInput(input[B])"
a -> b: "ok"
b -> a: "state: owner[display]=B"
b."lock"
b -> b: "Policy: target = most recently active other node, else home"
b -> mon: "push: setInput(input[target])"
b -> a: "state: presence[B]=inactive, owner[display]=target"
```

## 8. Security model

- A **group secret** of at least 32 random bytes (hex) is supplied in the user's configuration. It is never stored in the Spoon repository. Load it from a file outside git or from the Keychain. `DisplayKVM.generateSecret()` creates one.
- **No secret in URLs.** The HMAC provides authentication and integrity.
- **No encryption.** Messages carry only node names, display names and state, which are not confidential. DisplayKVM is not meant to cross untrusted networks.
- **LAN only.** The default port is 8765 and is configurable. Bonjour advertises the real port. The server can optionally be bound to one interface with `hs.httpserver:setInterface`.
- **Bonjour:** service type `_displaykvm._tcp`, TXT record `{v="1", group=<first 8 hex of SHA-256(secret)>, node=<node name>}`. The service name is the node name too, but only for readability: Bonjour may rename it on collision (`laptop (2)`), so peers identify each other by `txt.node`, never by the service name. Peers of a different group are skipped without revealing the secret.
- **Replay protection:** a 30 s timestamp window plus a nonce cache.
- **Risk:** the 30 s window needs clocks synced by NTP (the macOS default). Skew is rejected and logged.
- Requests from other groups and scanners get a bare 401. They are logged at debug level, rate-limited.

## 9. Configuration reference

The configuration is identical on every Mac in the group. Only `node` and how the secret is supplied differ.

```lua
hs.loadSpoon("DisplayKVM")
spoon.DisplayKVM:configure({
  node    = "desk-mini",              -- this computer's name; default hs.host.localizedName()
  secret  = "…64 hex chars…",         -- shared by the group (load from a file outside git or from Keychain)
  backend = "m1ddc",                  -- "m1ddc" | "ddcctl" | "betterdisplay" | "lunar" | function(display, input, done)
  displays = {
    left = {
      match  = { ["desk-mini"] = "<UUID as seen from desk-mini>", laptop = "<UUID as seen from laptop>" },
      inputs = { ["desk-mini"] = 15, laptop = 16 },
      home   = "desk-mini",
    },
  },
})
spoon.DisplayKVM:start()
spoon.DisplayKVM:bindHotkeys({ claim = { { "ctrl", "alt", "cmd" }, "M" } })  -- optional
```

| Field | Required | Default | Meaning |
|---|---|---|---|
| `node` | no | `hs.host.localizedName()` | Node name. Must appear in at least one `inputs`. |
| `secret` | yes | — | 64 hex characters (32 random bytes). `DisplayKVM.generateSecret()` helper. |
| `backend` | no | `"m1ddc"` | Built-in name or function `(display, input, done)`. |
| `backendOptions` | no | — | For example `{ path = "/opt/homebrew/bin/m1ddc" }` or `{ inputAlt = true }`. |
| `displays.<id>.match` | yes | — | A string is matched on every node: a value in UUID format is compared with the screen UUID, anything else is a plain substring of the screen name (not a Lua pattern). A table `{node = UUID or substring}` disambiguates identical monitors or different UUIDs per node. |
| `displays.<id>.inputs` | yes | — | `{node = DDC input}`. A node without an entry does not take part in that display. |
| `displays.<id>.home` | no | first node in `inputs` | Release target when no other node is active. |
| `displays.<id>.pull` | no | `true` | Set `false` for monitors that ignore DDC from an inactive input. Claims then always `request` the owner. |
| `port` | no | `8765` | Server port. |
| `peers` | no | — | Static list of `"host:port"` in addition to Bonjour. |
| `bonjour` | no | `true` | `false` disables discovery (static peers only). |
| `activity` | no | `{ userIdle = 5, startIdle = 30, lid = true }` | Thresholds. Use `lid = false` for desktops and clamshell users. |
| `heartbeat` | no | `30` | Seconds between `state` heartbeats. A node is absent after 3 silent intervals. |
| `logLevel` | no | `"info"` | Level of the `DisplayKVM` logger. |

**Validation.** `configure()` checks the schema: the node appears in some `inputs`, `home` has an input, the secret is long enough, and the binary of a built-in backend exists. On error it logs, shows a macOS notification, and `start()` does nothing.

**`status()`** returns the node name, the peers with their last-seen time, the owner of each display, and whether each display is locally visible.

**Caveat for publishers.** The default `node` is the machine's hostname. Anyone publishing their configuration should set `node` explicitly.

## 10. Error handling and edge cases

General rule: state is always repairable by the next event. Everything is logged. Notifications are sent only for actionable errors, rate-limited to 1 per 5 minutes per kind.

| Situation | Handling |
|---|---|
| Owner unreachable on claim (off, network down, asleep without release) | Send `request` to the owner. On failure, broadcast `request` to all alive peers: whoever sees the display pushes. At most 5 attempts per claim, with 2, 4, 8, 8 s between them, then log and notify "cannot claim <display>". The node keeps a *claim intent* while active and retries when the owner reappears (`hello`). |
| Release on `systemWillSleep` (little time) | The backend is called synchronously (`hs.task`, 2 s limit) and `owner = target` is written right after it. The state broadcast is synchronous too (`hs.http.doRequest`, 1 s per peer). Peers that missed it learn via `hello` after wake; meanwhile the broadcast-request fallback covers claims. |
| Two claims at the same moment | `owner` is decided by LWW. 3 s after a claim that went through `request`, the claimer verifies: if the merged state says `owner ~= self`, another node won — the claim intent is dropped and nothing more is sent. If `owner == self` but the display is still not visible (a "detaching" display showing another input), the claim is retried; this counts towards the 5-attempt limit. Always-visible displays cannot be verified this way (see limitations). |
| DDC command fails (exit ≠ 0, or 5 s timeout) | One retry after 1 s, then error log and notification. `owner` is not changed. A missing backend binary is detected by `configure()`. |
| Monitor auto-switches input on no signal | State may be stale. It is fixed by the next claim. Disabling auto input select in the monitor's OSD is recommended. |
| Laptop in clamshell mode with an external display | Default: lid close = release. Clamshell users set `activity.lid = false`. |
| No Bonjour/mDNS (VLANs, corporate networks) | Use the static `peers` list. Addresses are re-resolved on every discovery event. |
| Clock skew > 30 s | The receiver rejects with 401 and logs "clock skew with <peer>". The sender logs an NTP hint on 401. |
| First start, owner unknown (`owner = nil`) | The claimer pulls if the display is visible, otherwise broadcasts `request`. |
| Two nodes with the same name | Every message carries a random `instance`, new on every start. A new instance simply replaces the previous one (that is a reload or restart). A notification is raised only when an **older** instance is heard again after a newer one appeared within `2 × heartbeat` — two live processes are interleaving, which is a configuration error. |
| Node removed or renamed | Its presence expires after 3 intervals. An owner pointing to an unknown node is treated as unreachable, which triggers the broadcast fallback. |
| Foreign or invalid requests (other groups, scanners) | 401 without details. Debug-level log, rate-limited. |
| Start / reload | Send `hello` to all peers, then evaluate sensors: unlocked and idle < `startIdle` → active (claim). Otherwise presence is inactive and ownership is learned from the peers' replies. |
| Garbage collection | All watchers, timers and the server are fields of `Node`, held by `spoon.DisplayKVM`. No globals. |

**Documented limitations:**

- Always-visible displays cannot be verified after a switch.
- Clocks must be NTP-synced.
- LAN only.
- macOS only.

## 11. Testing strategy

| Level | What | How |
|---|---|---|
| Unit (pure Lua) | State merge (LWW, ties, idempotence, commutativity). Policy (target selection, stale presence, home fallback, home == self, node without input). Config validation. Message envelope (sign/verify, time window, replayed nonce). | `busted`. Clock, randomness and HMAC are injected, so no Hammerspoon is needed. |
| Node scenarios | Full flows on fakes of Transport, Display and the sensors: unlocking a laptop makes the laptop the owner; locking it returns the display to home; the home waking while the laptop is unlocked takes the display back; reload rules; three nodes with "last active"; owner unreachable → broadcast fallback; two simultaneous claims. | `busted` plus minimal `hs` fakes in `spec/support/`. |
| Static | Unused variables, accidental globals. | `luacheck` |
| CI | All of the above on every push. | GitHub Actions (Lua 5.4, `busted`, `luacheck`) |
| Hardware (manual) | Pre-check spike: does the monitor disappear from `hs.screen.allScreens()` after switching away, on each Mac? Then acceptance: the scenarios above, plus Wi-Fi off on the laptop (fallback), the hotkey, and `status()`. | Checklist, human, and logs. |

## 12. Repository layout and distribution

The **repository root is the Spoon**, so the repo can be cloned directly into `Spoons/DisplayKVM.spoon`.

```
init.lua  node.lua  state.lua  policy.lua  activity.lua
lid.lua   display.lua  transport.lua  discovery.lua
backends/            -- m1ddc, ddcctl, betterdisplay, lunar
spec/                -- busted specs; spec/support/ holds the hs fakes
docs/                -- design.md (this file), README material
.github/workflows/   -- CI
```

Install options:

- **git:** `git clone <repo URL> ~/.hammerspoon/Spoons/DisplayKVM.spoon`.
- **SpoonInstall:** SpoonInstall reads `<repo>/raw/<branch>/docs/docs.json` and `<repo>/raw/<branch>/Spoons/DisplayKVM.spoon.zip`. Because `main` holds the Spoon at its root, a CI job triggered by a version tag builds the zip and `docs/docs.json` (using `hs.doc.builder.genJSON`) and commits them to a separate **`dist`** branch laid out as `Spoons/DisplayKVM.spoon.zip` + `docs/docs.json`. Users register the repo in SpoonInstall with `branch = "dist"`. The same zip is attached to the GitHub release.

The repository must never contain secrets, a user's UUIDs or hostnames, or anything else specific to one setup. Examples use placeholders.

## 13. Clarifications

Points the first draft left implicit, now decided:

1. **Nonce cache retention.** A nonce is kept for 60 s (the full span in which a message with that timestamp can pass the ±30 s window), then evicted.
2. **Replies.** Validation failures return 401 with an empty body. Accepted `hello` returns 200 with the receiver's full state as JSON. Accepted `state` returns 204. Accepted `request` returns 200 with `{"result": "ok"}` or `{"result": "failed", "reason": "<short text>"}` (e.g. `not-visible`, `backend-error`).
3. **When `owner` is written.** Always after the switch succeeded — for claims and releases alike. On `systemWillSleep` the synchronous backend call returns before sleep, so `owner = target` is written immediately after it; only the broadcast of that change is best-effort.
4. **Default of `pull`.** The Spoon default stays `true`. A user whose hardware pre-check shows the monitor ignores DDC from an inactive input sets `pull = false` for that display.
