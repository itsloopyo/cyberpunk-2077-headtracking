# Cyberpunk 2077 Head Tracking

Use a webcam, phone, or VR headset to drive Night City's first-person camera with your head while your mouse or controller still controls aim, so you can lean into corners, peek around cover, and glance at your passenger without losing your shot.

<!-- Mod GIF placeholder. Replace with:
![Mod GIF](https://raw.githubusercontent.com/itsloopyo/cyberpunk-2077-headtracking/main/assets/readme-clip.gif)
once assets/readme-clip.gif is added. -->

> [!CAUTION]
> **Experimental prototype - expect missing core features**
>
> This is **not** a finished mod. Current builds may only test whether head tracking can drive the camera. Bug fixes and core features like decoupled look/aim, independent reticle behavior, correct shot direction, off-screen reticle support, movement handling, and comfort tuning may be missing at this early stage of development.

## Features

- **Decoupled look and aim** - head tracking moves the camera; your mouse or controller still controls aim
- **Projectile bullets** - player gunfire fires travelling rounds you can watch in flight instead of instant hitscan
- **6DOF positional tracking** - lean into corners and peek around cover with your head position

## Gameplay Changes

To decouple your shots from where your head is pointing, the mod switches **player** gunfire to the projectile attacks the game already ships, and uses them permanently rather than only during time dilation. This is a real gameplay change, so it is worth knowing what moves:

- **Rounds have travel time.** At any normal engagement distance you will not notice this, but at long range you lead a moving target slightly.
- **Bullets are physical objects.** They can be seen in flight, and they interact with the world rather than teleporting to the target.
- **Tech weapons are untouched.** Weapons that charge through cover keep their own behavior.
- **NPCs still use hitscan.** Only the player is converted, so there is no added cost from every enemy in a firefight spawning projectiles.
- **23 unique or quest weapons stay on hitscan** (MA70, AirDrop variants, Nova Doom Doom, and Saratoga Maelstrom among them) and will not decouple.

Everything is applied through TweakXL, so removing the mod restores stock behavior completely.

## Known Issues

**A few weapons still shoot hitscan.** 23 unique and quest weapons (MA70, the AirDrop variants, Nova Doom Doom and Saratoga Maelstrom among them) use their own attack records and are not converted, so aim stays coupled to your head on those. Every standard weapon is covered.

## Requirements

- [Cyberpunk 2077](https://store.steampowered.com/app/1091500/Cyberpunk_2077/) v2.x (Steam, GOG, or Epic).
- An OpenTrack-compatible head tracker: [OpenTrack](https://github.com/opentrack/opentrack) with a webcam or VR headset, or a phone app that speaks the OpenTrack UDP protocol.
- Windows 10 or 11, 64-bit.

## Installation

1. Download the latest installer ZIP from the [Releases page](https://github.com/itsloopyo/cyberpunk-2077-headtracking/releases).
2. Extract it anywhere (Desktop is fine).
3. Double-click `install.cmd`. It auto-detects Steam, GOG, and Epic installs, sets up the required mod loaders if they are missing, and deploys the mod.
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

If you would rather place files by hand, or you grabbed the Nexus ZIP (which contains only the deploy tree and no loaders):

1. Install [Cyber Engine Tweaks](https://github.com/maximegmd/CyberEngineTweaks/releases), [RED4ext](https://github.com/WopsS/RED4ext/releases), and [TweakXL](https://github.com/psiberx/cp2077-tweak-xl/releases) into your Cyberpunk 2077 folder. The installer ZIP also carries all three under `vendor/`, so you can extract those into the game root instead. Launch the game once so each loader initializes.
2. Copy `init.lua` and the `modules/` directory into:
   `<Cyberpunk 2077>\bin\x64\plugins\cyber_engine_tweaks\mods\HeadTracking\`
3. Copy `HeadTrackingAim.dll` into:
   `<Cyberpunk 2077>\red4ext\plugins\`
4. Copy `HeadTracking_ProjectileBullets.yaml` into:
   `<Cyberpunk 2077>\r6\tweaks\`

The Nexus ZIP is already laid out in this structure, so extracting it into the Cyberpunk 2077 folder does steps 2 through 4 in one go. Hotkeys need no setup: the keys in [Controls](#controls) are polled by `HeadTrackingAim.dll` and work as soon as the plugin loads.

## Setting Up OpenTrack

In OpenTrack, set **Output** to *UDP over network*:

- Remote IP: `127.0.0.1` (or your gaming PC's LAN IP if OpenTrack runs on another machine).
- Port: `4242`.

Pick any **Input** that suits your tracker. Click **Start** before launching the game. Allow UDP 4242 through Windows Firewall when prompted.

### VR Headset Setup

You can use a VR headset purely as a head tracker. There is no VR rendering, you still play on your monitor.

1. Connect the headset to your PC with Air Link, Virtual Desktop, or a link cable, and start SteamVR.
2. In OpenTrack, set **Input** to *SteamVR / OpenVR*. OpenTrack reads the headset's orientation from SteamVR.
3. Set Output to *UDP over network* targeting `127.0.0.1:4242` as above, then click **Start**.
4. Recenter in-game (`Home` or `Ctrl+Shift+T`) once you are looking forward at the screen.

### Webcam Setup

1. Install OpenTrack from its [releases page](https://github.com/opentrack/opentrack/releases).
2. In OpenTrack, set **Tracker** to *Neuralnet Tracker*, which works without IR markers.
3. Select your webcam, run the calibration wizard, and confirm the head model follows your movements in OpenTrack's preview.
4. Set Output as above and click **Start**.

### Phone App Setup

Most phone trackers (Headcam, SmoothTrack, OpenTrack Companion) can speak OpenTrack UDP directly:

- **Direct send**: point the app at your PC's LAN IP on port `4242`. Use this if the app already smooths the signal.
- **Via OpenTrack**: have the phone send to OpenTrack on a different port (for example 4243), then OpenTrack's Output forwards to `127.0.0.1:4242`. Use this if you want OpenTrack's curve mapping or filters in the chain.

The mod's internal smoothing and deadzone are independent of the phone app, so duplicate filtering is fine but unnecessary.

## Controls

Two equivalent binding sets, so use whichever your keyboard has. Both sets are always active: a nav-cluster key and its chord fire the same action, and pressing either triggers it once.

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

Edit it directly, or use the in-game Native Settings UI if you have it installed. The defaults below are what the mod ships with:

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

JSON has no comment syntax, so the settings worth touching are described here instead:

- `sensitivity_*` (0.1 to 5.0): per-axis rotation multiplier. Raise pitch if you want more vertical range from less head movement.
- `smoothing_factor` (0.0 to 0.99): 0 is snappy, 0.9 is heavy. A floor of 0.15 is enforced internally to suppress jitter on high-refresh displays.
- `clamp_*` (degrees): rotation caps, so head rotation cannot fight the aim system.
- `crosshair_*`: parallax-correct reticle overlay. Set `crosshair_fov_degrees` to your in-game FOV so the marker tracks the true aim point at extreme head angles.
- `ads_reticle_*`: custom aim-down-sights reticle drawn at the true aim point while aiming. `ads_reticle_size` is in pixels, `ads_reticle_opacity` runs 0.0 to 1.0.
- `position_*`: 6DOF translation. Sensitivities are per-axis multipliers, limits are in meters.
- `yaw_mode`: `"world"` is horizon-locked yaw, so head yaw always swings around world vertical no matter how far the view has pitched. `"local"` pivots around the camera's current up-axis instead, which tilts with mouse pitch. Toggle live with `Page Down` / `Ctrl+Shift+H`, but note this one is **not persisted**: every launch starts back in `"world"`, so the toggle lasts for the session only.

## Troubleshooting

**Mod not loading.**
- Confirm CET opens in-game (default key `~`). If it does not, fix CET first.
- Check `<Cyberpunk 2077>\red4ext\logs\red4ext.log` for `[HeadTrackingAim] UDP receiver listening on port 4242`. If that line is absent, RED4ext did not load the native plugin. Reinstall RED4ext and re-run `install.cmd`.
- Open the CET console and look for `[HeadTracking]` messages from the Lua side.

**No tracking response.**
- Make sure OpenTrack (or your phone app) is sending UDP to `127.0.0.1:4242` and has been **Start**ed.
- Allow UDP 4242 through Windows Firewall.
- If the tracker runs on a different machine, send to your gaming PC's LAN IP, not `127.0.0.1`.
- If `red4ext.log` shows `Failed to bind UDP port 4242`, another app is holding the port (a second head-tracking mod, or a leftover game process). Close it and tracking comes back on its own within about half a second. The receiver retries the port every 500ms in the background and logs `Bound UDP port 4242` when it gets in, so no game restart is needed.

**Jittery or unstable tracking.**
- Raise `smoothing_factor` toward 0.3 to 0.5.
- For phone trackers, enable smoothing in the phone app or relay through OpenTrack with a low-pass filter.
- High-FPS displays show micro-jitter more readily. The 0.15 internal floor is the minimum that is ever applied.

**Wrong rotation axis (camera moves the wrong way).**
- Invert the offending axis in OpenTrack under **Output > Mapping** rather than in the mod. The mod has no inversion setting on purpose.
- For yaw that feels off only when looking up or down, toggle yaw mode with `Page Down` / `Ctrl+Shift+H`.

## Updating

Download the new release ZIP and run `install.cmd` again. Your `config.json` is preserved.

## Uninstalling

Run `uninstall.cmd`. This removes the mod's Lua tree under `bin\x64\plugins\cyber_engine_tweaks\mods\HeadTracking\`, the `HeadTrackingAim.dll` native plugin, and the TweakXL yaml under `r6\tweaks\`, which restores stock hitscan gunfire.

Cyber Engine Tweaks, RED4ext, and TweakXL are shared modding frameworks that your other mods likely depend on, so they are left in place even when you pass `uninstall.cmd /force`. Remove them by hand if you want the game fully vanilla.

## Building from Source

Prerequisites: [pixi](https://pixi.sh), Visual Studio 2019 or 2022 with the Desktop development with C++ workload, and a local Cyberpunk 2077 install.

```powershell
git clone --recurse-submodules https://github.com/itsloopyo/cyberpunk-2077-headtracking.git
cd cyberpunk-2077-headtracking
pixi run install    # build the native plugin and deploy to the detected game install
pixi run package    # produce installer and Nexus ZIPs in release/
```

## License

MIT License - see [LICENSE](LICENSE) for details.

Third-party components are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) with their respective licenses.

## Credits

- CD PROJEKT RED for Cyberpunk 2077.
- [Cyber Engine Tweaks](https://github.com/maximegmd/CyberEngineTweaks) by maximegmd, hosting the Lua mod.
- [RED4ext](https://github.com/WopsS/RED4ext) and [RED4ext.SDK](https://github.com/WopsS/RED4ext.SDK) by WopsS, loading the native plugin.
- [TweakXL](https://github.com/psiberx/cp2077-tweak-xl) by psiberx, applying the projectile-bullet record changes.
- [GameUI](https://github.com/psiberx/cp2077-cet-kit) by psiberx, for game-state detection.
- [OpenTrack](https://github.com/opentrack/opentrack) for the head-tracking UDP protocol.
- [Dear ImGui](https://github.com/ocornut/imgui) by Omar Cornut, for the in-game crosshair overlay, used through CET.

## Disclaimer

This mod is not affiliated with, endorsed by, or supported by CD PROJEKT RED. It is a single-player utility, so do not use it in any multiplayer or competitive context. Use at your own risk.

## Community and Support

- [Discord](https://discord.com/invite/dxyZdyFNT9) - setup help, bug reports, and new-release announcements
- [Lopari](https://lopari.app) - free Windows launcher with one-click install and launch of head-tracking mods
- [Headcam](https://headcam.app) - free app that turns your phone into a head tracker
