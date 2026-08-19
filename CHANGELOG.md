# Changelog

## [Unreleased]

### Added

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

- Vendored TweakXL bumped to 1.11.4.
- `uninstall.cmd` removes the mod's four hotkeys from CET's shared
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
