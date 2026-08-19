# Changelog

## [Unreleased]

### Changed

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
