# Changelog

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
