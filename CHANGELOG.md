# Changelog

## [1.0.1] - 2026-08-20

### Added

- retire the recenter hotkey and truncate the Lua diag logs per launch
- replace the RedSocket TCP transport with direct RTTI script calls

## [1.0.0] - 2026-08-20

### Added

- drop the mod-side auto-recenter and ride hit markers with the reticle
- remove mod-side recentring and rotate the native log per launch

## [0.3.0] - 2026-08-19

### Added

- split smoothing into local and remote, drop the hidden floor
- gate the RVA-pinned hooks behind a PE build-profile registry
- stand tracking down while aiming down sights

### Fixed

- expire the extrapolation instead of parking on it
- interpolate yaw and roll along the shortest arc
- capture the neutral from a raw sample, not an interpolated blend
- drop the previous-frame head quat on recenter

## [Unreleased]

### Added

- `red4ext/logs/HeadTrackingAim.log` now starts fresh on every game
  launch, keeping the previous launch as `HeadTrackingAim.prev.log`.
  It was opened in append mode, so the two 3s heartbeats grew it by
  roughly 325 KB per hour of play with no upper bound across
  sessions, and the startup lines worth reading ended up buried.

- The Lua side's `crash-trace.log` and `yaw-diag.log` are emptied at startup.
  Both were append-only, so a file sent in for diagnosis carried every earlier
  session's errors alongside the one being reported.

- The native plugin now fingerprints the running `Cyberpunk2077.exe`
  (TimeDateStamp + SizeOfImage + CheckSum) and routes its hardcoded
  addresses through a build-profile registry. On a build it does not
  recognise, every RVA-pinned hook stays dormant and the log names the
  running fingerprint, each known build, and whether the game is newer,
  older, or repacked. Previously those hooks were only bounds-checked,
  so after a game patch they would have been written into whatever
  function had moved into their place. Head tracking, the camera, and
  projectile aim decoupling resolve their targets by name and are
  unaffected either way. Ships with the GOG 2.31 build
  (`gog-win64-20250827`); further builds are added, never edited in
  place, so an older game keeps working with a newer mod.
- `pixi run check-fingerprint` prints an installed game EXE's
  fingerprint and a paste-ready build-profile stub.
- `install.cmd` compares an already-installed Cyber Engine Tweaks,
  RED4ext, or TweakXL against the bundled version. An out-of-date loader
  is now reported instead of being silently accepted, which was the most
  likely way for an install to report success and then do nothing in
  game. Interactive runs offer to replace it; `/y` runs report and leave
  it alone; the new `/upgrade-deps` flag replaces it unattended.
- `install.cmd` and `uninstall.cmd` check they can write to the game
  folder before starting, so a protected install location (Epic's
  default) says "run as administrator" instead of failing partway
  through with a PowerShell access-denied trace.

### Changed

- Recentring is gone entirely: the hotkey (`Home` / `Ctrl+Shift+T`), the Native
  Settings "Recenter Now" button, and the whole centre-offset pipeline. Your
  tracker owns the centre now. Centre it there - OpenTrack's Center bind,
  SteamVR, or your phone app - and the mod applies what it sends without
  keeping a second centre of its own.

  Two centres in series was the problem: when the view was off, you could not
  tell which side was wrong, and switching between trackers meant recentring in
  both. With one centre there is nothing to disagree about.
- Vendored TweakXL bumped to 1.11.4.
- `uninstall.cmd` removes the mod's three hotkeys from CET's shared
  `bindings.json` and deletes the backup it made at install time, rather
  than leaving a HeadTracking section behind claiming keys for a mod
  that is gone. Other mods' bindings are preserved.
- `install.cmd` and `uninstall.cmd` verify the resolved folder actually
  contains the game before reporting "Game found".
- Release ZIPs are written with forward-slash entry names. Windows
  PowerShell's `Compress-Archive` uses backslashes, which the ZIP spec
  does not permit and non-Windows tooling does not have to accept.

- Smoothing is now two settings instead of one: `local_smoothing`
  (default `0.0`) for a tracker running on this machine, and
  `remote_smoothing` (default `0.15`) for a remote device sending over
  the network. Both cover rotation and position, so `smoothing_factor`
  and `position_smoothing` are gone. Both appear as sliders under
  Settings > Head Tracking > Smoothing.
- Removed the hidden `0.15` baseline floor. It silently overrode the
  configured value, so local users now get zero-latency tracking by
  default instead of a forced 0.15.
- The native RED4ext plugin now reports whether tracking packets are
  arriving from off-box (loopback sender = local, anything else =
  remote) as a live status bit on the TCP protocol, and Lua re-reads it
  every frame. Switching between a local OpenTrack instance and a phone
  on WiFi takes effect without a game restart.

## [0.2.0] - 2026-08-11

### Changed

- Performance and stability improvements

## [0.1.0] - 2026-08-11

### Added

- switch player gunfire to projectile attacks for aim decoupling

### Fixed

- bump cameraunlock-core so a busy tracker port is recoverable
- guard native hooks on unknown builds, plug leaks, ship licences

### Other

- Add release nightly dispatch and publisher shim

## [Unreleased]

### Added
- Added head-tracked first-person and vehicle camera driven by OpenTrack UDP pose data.
- Added decoupled look and aim so the head moves the view while mouse or controller still controls aim.
- Added projectile player gunfire through TweakXL, replacing hitscan so shots can be decoupled from the view.
- Added 6DOF positional tracking for leaning into corners and peeking around cover.
- Added an offset crosshair overlay marking where shots will land.
- Added Home / End / Page Up / Page Down hotkeys with Ctrl+Shift+T / Y / G / H chord alternatives.
- Added in-game configuration through Native Settings.
