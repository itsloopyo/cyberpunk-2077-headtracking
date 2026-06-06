> [!CAUTION]
> ## Experimental prototype - expect missing core features
>
> This is **not** a finished mod.
>
> Current builds may only test whether head tracking can drive the camera. Bug fixes and core features like decoupled look/aim, independent reticle behavior, correct shot direction, off-screen reticle support, movement handling, and comfort tuning may be missing at this early stage of development.

# Cyberpunk 2077 Head Tracking

Use a webcam or phone to drive Night City's first-person camera with your head while your mouse or controller still controls aim, so you can lean into corners, peek around cover, and glance at the passenger without losing your shot.

<!-- Mod GIF placeholder. Replace with:
![Mod GIF](https://raw.githubusercontent.com/itsloopyo/cyberpunk-2077-headtracking/main/assets/readme-clip.gif)
once assets/readme-clip.gif is added. -->

## Features

- **Decoupled look and aim** - head tracking moves the camera; your mouse or controller still controls aim.
- **Parallax-correct aim reticle** - a second reticle marks where bullets will actually land while you look around.

## Known Issues

**Shooting is imperfect.** On every LMB action (firing, punching, reloading, holstering, even empty-mag clicks) the engine briefly snaps the camera toward the mouse-aim direction for a single frame. The mod masks this by holding the last good frame over the snap frame, so in normal play you should not see it. It is a cosmetic artifact, not a true fix.

**Turn off frame generation and motion blur.** Both make the click flick more visible. The mod is built and tested without either; with frame gen on, the engine interpolates the flicked frame into adjacent frames and smears the snap across a longer visible window.

## Requirements

- [Cyberpunk 2077](https://store.steampowered.com/app/1091500/Cyberpunk_2077/) v2.x (Steam, GOG, or Epic).
- An OpenTrack-compatible head tracker - [OpenTrack](https://github.com/opentrack/opentrack) with a webcam, or a phone app that speaks the OpenTrack UDP protocol.
- Windows 10 or 11, 64-bit.

## Installation

1. Download the latest installer ZIP from the [Releases page](https://github.com/itsloopyo/cyberpunk-2077-headtracking/releases).
2. Extract it anywhere (Desktop is fine).
3. Double-click `install.cmd`. It auto-detects Steam, GOG, and Epic installs and deploys the Lua mod plus the native RED4ext plugin.
4. Configure your tracker to send OpenTrack UDP to `127.0.0.1:4242` (see [Setting Up OpenTrack](#setting-up-opentrack)).
5. Launch Cyberpunk 2077.

If the installer cannot find your game, point it at the install root explicitly:

```powershell
install.cmd "D:\Games\Cyberpunk 2077"
```

Or set the `CYBERPUNK_2077_PATH` environment variable before running `install.cmd`:

```powershell
$env:CYBERPUNK_2077_PATH = "D:\Games\Cyberpunk 2077"
.\install.cmd
```

### Manual Installation

If you would rather place files by hand (or you grabbed the Nexus ZIP, which contains only the deploy tree):

1. Install [Cyber Engine Tweaks](https://github.com/maximegmd/CyberEngineTweaks/releases) and [RED4ext](https://github.com/WopsS/RED4ext/releases) into your Cyberpunk 2077 folder. Launch the game once so each loader initializes.
2. Copy `init.lua` and the `modules/` directory into:
   `<Cyberpunk 2077>\bin\x64\plugins\cyber_engine_tweaks\mods\HeadTracking\`
3. Copy `HeadTrackingAim.dll` into:
   `<Cyberpunk 2077>\red4ext\plugins\HeadTrackingAim\`
4. Optionally edit `bindings.json` under
   `<Cyberpunk 2077>\bin\x64\plugins\cyber_engine_tweaks\` to set the hotkeys
   listed in [Controls](#controls). The installer normally merges these for you.

## Setting Up OpenTrack

In OpenTrack, set **Output** to *UDP over network*:

- Remote IP: `127.0.0.1` (or your gaming PC's LAN IP if OpenTrack runs on another machine).
- Port: `4242`.

Pick any **Input** that suits your tracker. Click **Start** before launching the game. Allow UDP 4242 through Windows Firewall when prompted.

### VR Headset Setup

You can use a VR headset purely as a head tracker (no VR rendering, you still play on your monitor):

1. Connect the headset to your PC with Air Link, Virtual Desktop, or a link cable, and start SteamVR.
2. Install OpenTrack and set **Input** to *SteamVR / OpenVR*. OpenTrack reads the headset's orientation from SteamVR.
3. Set Output to *UDP over network* targeting `127.0.0.1:4242` as above, then click **Start**.
4. Recenter in-game (`Home` / `Ctrl+Shift+T`) once you are looking forward at the screen.

### Webcam Setup

1. Install OpenTrack from its [releases page](https://github.com/opentrack/opentrack/releases).
2. In OpenTrack, set **Tracker** to *Neuralnet Tracker* (works without IR markers).
3. Select your webcam, run the calibration wizard, and confirm the head model follows your movements in OpenTrack's preview.
4. Set Output as above and click **Start**.

### Phone App Setup

Most phone trackers (Head Tracker, SmoothTrack, OpenTrack Companion) can speak OpenTrack UDP directly:

- **Direct send**: point the app at your PC's LAN IP on port `4242`. Use this if the app already smooths the signal.
- **Via OpenTrack**: have the phone send to OpenTrack on a different port (for example 4243), then OpenTrack's Output forwards to `127.0.0.1:4242`. Use this if you want OpenTrack's curve mapping or filters in the chain.

The mod's internal smoothing and deadzone are independent of the phone app, so duplicate filtering is fine but unnecessary.

## Controls

The two columns are equivalent - use whichever your keyboard has. All bindings are rebindable in **Cyber Engine Tweaks > Bindings > HeadTracking**.

| Action              | Nav-cluster | Chord           |
|---------------------|-------------|-----------------|
| Recenter            | `Home`      | `Ctrl+Shift+T`  |
| Toggle tracking     | `End`       | `Ctrl+Shift+Y`  |
| Cycle tracking mode | `Page Up`   | `Ctrl+Shift+G`  |
| Toggle yaw mode     | `Page Down` | `Ctrl+Shift+H`  |

`Page Up` / `Ctrl+Shift+G` cycles tracking mode:

1. Normal head-tracked gameplay
2. Positional tracking disabled, rotational tracking enabled
3. Rotational tracking disabled, positional tracking enabled
4. Back to normal

## Configuration

The mod writes its config to:

```
<Cyberpunk 2077>\bin\x64\plugins\cyber_engine_tweaks\mods\HeadTracking\config.json
```

You can edit it directly, or use the in-game Native Settings UI (if installed). Defaults below match what the mod ships with:

```json
{
  "enabled": true,
  "sensitivity_yaw": 1.0,
  "sensitivity_pitch": 1.0,
  "sensitivity_roll": 1.0,
  "smoothing_factor": 0.0,

  "clamp_yaw": 120.0,
  "clamp_pitch": 80.0,
  "clamp_roll": 45.0,

  "crosshair_enabled": true,
  "crosshair_fov_degrees": 84.0,
  "crosshair_lead_factor": 0.0,

  "ads_reticle_enabled": true,
  "ads_reticle_size": 12,
  "ads_reticle_opacity": 0.8,

  "position_enabled": true,
  "position_sens_x": 1.0,
  "position_sens_y": 1.0,
  "position_sens_z": 1.0,
  "position_limit_x": 0.30,
  "position_limit_y_up": 0.20,
  "position_limit_y_down": 0.05,
  "position_limit_z_fwd": 0.40,
  "position_limit_z_back": 0.10,
  "position_smoothing": 0.15,

  "yaw_mode": "world"
}
```

Knobs you will actually touch:

- `sensitivity_*` (0.1 to 5.0): per-axis multiplier. Bump pitch up if you want more vertical range with less head movement.
- `smoothing_factor` (0.0 to 0.99): 0 is snappy, 0.9 is heavy. A floor of 0.15 is enforced internally to suppress jitter on high-refresh displays.
- `clamp_*` (degrees): "Soft Look" rotation caps. Cyberpunk-specific safety limit so head rotation cannot fight the aim system.
- `crosshair_*`: parallax-correct reticle overlay. Set `crosshair_fov_degrees` to your in-game FOV so the marker tracks the true aim point on extreme head angles.
- `ads_reticle_*`: custom aim-down-sights reticle drawn at the true aim point while aiming. `ads_reticle_size` is in pixels; `ads_reticle_opacity` is 0.0 to 1.0.
- `yaw_mode`: `"world"` is horizon-locked yaw (default). `"local"` pivots around the camera's current up-axis, which tilts with mouse pitch. Toggle live with `Page Down` / `Ctrl+Shift+H`.

## Troubleshooting

**Mod not loading.**
- Confirm CET opens in-game (default key `~`). If it does not, fix CET first.
- Check `<Cyberpunk 2077>\red4ext\logs\red4ext.log` for `[HeadTrackingAim] UDP receiver listening on 0.0.0.0:4242`. If that line is absent, RED4ext did not load the native plugin - reinstall RED4ext and re-run `install.cmd`.
- Open the CET console and look for `[HeadTracking]` messages from the Lua side.

**No tracking response.**
- Make sure OpenTrack (or your phone app) is sending UDP to `127.0.0.1:4242` and is **Start**ed.
- Allow UDP 4242 through Windows Firewall.
- If the tracker runs on a different machine, send to your gaming PC's LAN IP, not `127.0.0.1`.

**Jittery or unstable tracking.**
- Raise `smoothing_factor` toward 0.3 to 0.5.
- For phone trackers, enable smoothing in the phone app or relay through OpenTrack with a low-pass filter.
- High-FPS displays show micro-jitter more readily; the 0.15 internal floor is the minimum you can apply.

**Wrong rotation axis (camera moves the wrong way).**
- Invert the offending axis in OpenTrack under **Output > Mapping** rather than in the mod. The mod has no inversion setting on purpose.
- For yaw that feels off only when looking up or down, toggle yaw mode with `Page Down` / `Ctrl+Shift+H`.

More detail in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Updating

Download the new release ZIP and run `install.cmd` again. Your `config.json` and bindings are preserved.

## Uninstalling

Run `uninstall.cmd`. This removes the mod's Lua tree under
`bin\x64\plugins\cyber_engine_tweaks\mods\HeadTracking\` and the
`HeadTrackingAim.dll` native plugin. CET and RED4ext are not removed (this mod
never installs them for you). To force-remove a mod loader anyway, run
`uninstall.cmd /force`.

## Building from Source

Prerequisites: [pixi](https://pixi.sh), Visual Studio 2019 or 2022 (Desktop development with C++), and a local Cyberpunk 2077 install.

```powershell
git clone --recurse-submodules https://github.com/itsloopyo/cyberpunk-2077-headtracking.git
cd cyberpunk-2077-headtracking
pixi run install    # build native plugin + deploy to detected game install
pixi run package    # produce installer + nexus ZIPs in release/
pixi run release 1.0.0
```

## Credits

- CD PROJEKT RED for Cyberpunk 2077.
- [Cyber Engine Tweaks](https://github.com/maximegmd/CyberEngineTweaks) by maximegmd, hosting the Lua mod.
- [RED4ext](https://github.com/WopsS/RED4ext) and [RED4ext.SDK](https://github.com/WopsS/RED4ext.SDK) by WopsS, loading the native plugin.
- [OpenTrack](https://github.com/opentrack/opentrack) for the head-tracking UDP protocol.
- [GameUI](https://github.com/psiberx/cp2077-cet-kit) by psiberx, for game-state detection.
- [Dear ImGui](https://github.com/ocornut/imgui) by Omar Cornut, for the in-game crosshair overlay (used through CET).

## License

MIT - see [LICENSE](LICENSE). Copyright (c) 2026 itsloopyo.

Third-party components are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) with their respective licenses.

## Disclaimer

This mod is not affiliated with, endorsed by, or supported by CD PROJEKT RED. It is a single-player utility - do not use it in any multiplayer or competitive context. Use at your own risk.
