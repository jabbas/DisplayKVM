# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- DisplayKVM tells you when the monitor's buttons are needed. With the monitor's automatic input switching off
  (recommended), a cable pulled while its Mac owns the display, without a lock first, leaves the monitor on that input
  with no picture. The Mac that lost the display now logs a warning and notifies "<display> was disconnected while it
  showed this Mac. If the monitor has no picture, switch its input with the monitor's buttons." The home Mac without
  DDC, when its claim (unlock, wake, the hotkey or `claim()`) ends without any Mac in `control` able to switch the
  monitor to it, warns and notifies "Cannot switch <display> to this Mac. ..." once per such event; the usual case
  (the controller released the display and is now locked or unplugged) stays silent.
- Owner records written by the repairs without DDC (a controller lost the display, every controller is gone) carry
  `assumed = true` in the replicated state until a real switch replaces them; `status()` shows it as
  `displays[id].assumed`. A 0.2.2 peer ignores the field and cannot clear it by sending the record back, but it never
  sets it either: update every Mac.

### Changed

- A claim of a Mac without DDC no longer accepts an `assumed` record naming itself before its last attempt: a Mac in
  `control` that comes back during the retries (for example after a reboot) is asked to switch the monitor.
- A release that lands while the state already names its target through an `assumed` record now writes a confirmed
  record.
- A claim whose display is not connected to this Mac now also ends quietly (one info line, no error, no notification)
  when other Macs are alive but none of them can switch the display (none in `control`), for example a laptop at home
  with its cable out while only the home Mac without DDC is on the network. The line now reads "<display> is not
  connected here and no other node that can switch it is reachable; not claiming".

## [0.2.2]

Housekeeping: switching behaves exactly as in 0.2.1; only logs, notifications and docs change.

### Changed

- A claim whose display is still not connected to this Mac while no other node is reachable (for example a laptop
  away from home) no longer ends with the error `cannot claim <display>` and a notification on every unlock. It keeps
  its retries and ends with one info line, "<display> is not connected here and no other node is reachable; not
  claiming". With any other node alive a failed claim is still an error with a notification.

### Added

- One info log line per successful switch on each node involved: a pull (`switched left to laptop
  (screensDidUnlock)`), a claim granted through `request` (`left switched to desk-mini by laptop`), the `request`
  served on the controller (`switched left to desk-mini for desk-mini`), a release (`switched left to desk-mini
  (release: screensDidLock)`) and a release handed to a node in `control` (`left switched to laptop via laptop
  (release: ...)`). Failed and suppressed switches add no line. The previous separate info line "release of ...
  landed but ... owns it now" is now part of the release's switch line.

### Documentation

- Turning the monitor's automatic input switching off (Auto-Switch Input and related USB-C options) is now
  recommended in every setup; 0.2.0 and 0.2.1 recommended keeping it on for `control` / `whenAway` setups. With it
  on, a monitor can jump to another Mac's input when the current one blanks its display, or bounce back when the
  DDC switch arrives before the new Mac's video is up. The trade-off (an unplugged cable leaves the monitor on that
  input until it is switched with its buttons) is described in the README.
- Known limitations: a DDC backend such as `m1ddc` reports success even when the monitor ignored or undid the change,
  which DisplayKVM cannot detect on a monitor that stays listed on every input.

## [0.2.1]

### Fixed

- A node outside `control` that claims a display right after a start or Hammerspoon reload (an active start,
  an unlock or the hotkey) no longer takes it for granted that the display shows it ("no controller reachable
  for ...; assuming it shows this node") before it has heard from any node in `control`. The claim now waits
  for discovery and sends its `request` to the controller as soon as one is heard, so the monitor is really
  switched instead of the state naming the home node while the monitor still shows another node. The
  assumption is only made after the last attempt (about 22 seconds), still without an error or a
  notification. A mirror left by the previous run is kept while such a claim waits.

## [0.2.0]

### Added

- `displays.<id>.control`: the nodes that can switch a display over DDC (default: every node in `inputs`, so
  0.1.x configurations behave as before). A node outside `control` never runs the backend for the display; every
  switch it needs, to itself or handed to another node, is sent as a `request` to a live node in `control`.
- `displays.<id>.whenAway` (`{ node = "mirror" }`) and `mirrorTo`: a node hides a display that another node owns by
  mirroring it onto another screen (its primary screen by default), pulls windows left half off the edge back into
  the screen, and stops the mirror when it owns the display again, at `stop()`, and after a reload (the mirror
  left by a previous run is inferred at start from the display missing among the screens, a heuristic, with a 5 second
  grace period while the owner is unknown).
  For monitors that stay listed on every Mac whatever input is selected.
- State recovery without DDC. A node in `control` that owned a display and no longer sees it records
  `owner = home` (checked 2 seconds after a screen change and on every heartbeat), and the home node takes
  the ownership in the state when the owner and every node in `control` are gone (about 90 to 120 seconds). The first only
  applies when the home node cannot switch the display itself.
- The `screenWatcher` and `away` dependencies of `Node`, and the new module `away.lua` (the only code that uses
  `hs.screen:mirrorOf`, `mirrorStop` and `hs.window:setFrameInScreenBounds`).

### Changed

- A `request` to a node outside `control` is answered with `failed` and the reason `not-capable` and sends no DDC.
- The verification 3 seconds after a switch that went through a `request` is skipped for a node that mirrors the
  display (`whenAway`): the display is hidden by that node's own doing and says nothing about the monitor.

### Notes

- Update every node together. A 0.1.x node does not know `control` and may address its DDC commands and
  `request`s to a node that cannot handle them.
- Known limitations are described in the README: the HDMI port of a Mac mini M1 has no working DDC and `m1ddc`
  reports success anyway; a controller that hangs with the cable plugged in leaves the monitor asleep; macOS display
  mirroring briefly reconfigures the displays; mirror recovery after a crash is a heuristic.

## [0.1.1]

### Fixed

- Consecutive inactivity events (for example lock followed by sleep, or lid close followed by lock) no longer
  start a second release of the same display while the first one is in flight, and a release that finds the
  display already handed over is logged at info level instead of as an error. This removes the
  `release of ... failed: backend-error|not-visible` log noise on lock, sleep and lid close.
- Pending switch retries and running backend tasks are cancelled when the Spoon is stopped.
- Function backends that raise an error are treated as a failed attempt instead of breaking the caller.
- A Bonjour service that resolves without a hostname or port is skipped, and the transport never builds a URL
  from a missing host or port.
- A lid that is already closed when the Spoon starts is now treated like a lid close.

### Security

- The message time window is computed in floating point, so an integer wrap-around can no longer let a
  forged timestamp pass; NaN and infinite timestamps are rejected as malformed.
- The signature comparison has no data-dependent branch in its loop.
- `Message.new` asserts that `nonceTtl` is at least twice the time window.

### Changed

- Release tags are now `X.Y.Z` without a `v` prefix, and the release workflow checks the tag against
  `obj.version` exactly.
- The release archive includes this changelog.

## [0.1.0]

Initial release (tagged `v0.1.0`).

- Shares one or more monitors between several Macs by switching the monitor input over DDC/CI when the user
  becomes active (unlock, wake, start) on a Mac and handing it over on lock, sleep or lid close.
- Nodes find each other with Bonjour or a static peer list and exchange HMAC-signed messages over HTTP.
- Backends: `m1ddc`, `ddcctl`, `betterdisplay`, `lunar`, or a user function.
- Installable with SpoonInstall (`dist` branch) or git.

[0.2.2]: https://github.com/jabbas/DisplayKVM/releases/tag/0.2.2
[0.2.1]: https://github.com/jabbas/DisplayKVM/releases/tag/0.2.1
[0.2.0]: https://github.com/jabbas/DisplayKVM/releases/tag/0.2.0
[0.1.1]: https://github.com/jabbas/DisplayKVM/releases/tag/0.1.1
[0.1.0]: https://github.com/jabbas/DisplayKVM/releases/tag/v0.1.0
