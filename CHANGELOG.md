# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

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

[0.2.0]: https://github.com/jabbas/DisplayKVM/releases/tag/0.2.0
[0.1.1]: https://github.com/jabbas/DisplayKVM/releases/tag/0.1.1
[0.1.0]: https://github.com/jabbas/DisplayKVM/releases/tag/v0.1.0
