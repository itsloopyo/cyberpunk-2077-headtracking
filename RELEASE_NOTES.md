## What's Changed in v1.2.0

### Added

- Three aim-down-sights modes, cycled in game with `Insert`: tracking paused, tracking on with an aim marker, tracking on without one
- Raising the sights swings the view onto the point the reticle was marking, so the shot lands where you lined it up
- A white aim marker drawn at the true impact point while aiming down sights
- ADS mode, yaw mode and the 6DOF position limits in the settings panel

### Changed

- Sensitivity, deadzones and response curves are gone from the mod - set them in OpenTrack or your tracking app and the mod consumes the pose at 1:1
- Retired sensitivity and deadzone keys are stripped from `config.json` on load, with a log line naming what came out
- The white ADS aim marker is authoritative for scoped weapons; a scope's own reticle is only true while your eye sits on the optic
- The frozen-centre ADS mode is gone; configs holding the old `reticle` name migrate to `paused` on load

### Fixed

- The Native Settings panel works again - it registered nothing usable before, so changes never reached the mod
- Page Up's position-only mode no longer has rotation switched back on by the settings panel
- The reticle projects through the live aim distance, so it stays on target when you lean
- Rounds land on the reticle while leaning
- Hit and kill markers appear on the surface the round struck instead of at screen centre
- The ricochet preview line follows the path the round actually takes
- ADS mode switching no longer leaves tracking in a stale state
