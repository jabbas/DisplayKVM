# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

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

[0.1.1]: https://github.com/jabbas/DisplayKVM/releases/tag/0.1.1
[0.1.0]: https://github.com/jabbas/DisplayKVM/releases/tag/v0.1.0
