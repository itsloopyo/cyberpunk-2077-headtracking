# Cyberpunk 2077 Head Tracking

![Mod GIF](https://raw.githubusercontent.com/itsloopyo/cyberpunk-2077-headtracking/main/assets/readme-clip.gif)

Use a webcam, phone, or VR headset to drive Night City's first-person camera with your head while your mouse or controller still controls aim, so you can lean into corners, peek around cover, and glance at your passenger without losing your shot.

## Features

- **Decoupled look and aim** - head tracking moves the camera; your mouse or controller still controls aim
- **6DOF positional tracking** - lean into corners and peek around cover with your head position
- **Three ways to aim down sights** - hand the camera back to the game, hold the view still and put the sights on the centre of the screen, or keep tracking live through the whole aim. Cycled in game with `Home`

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
- An OpenTrack-compatible head tracker: [OpenTrack](https://github.com/opentrack/opentrack) with a webcam or VR headset, or a phone app that speaks the OpenTrack UDP protocol (see [Phone App Setup](#phone-app-setup) for which apps can send straight to the mod and which need OpenTrack in the chain).
- Windows 10 or 11, 64-bit.

## Installation

1. Download the latest installer ZIP from the [Releases page](https://github.com/itsloopyo/cyberpunk-2077-headtracking/releases).
2. Extract it anywhere (Desktop is fine).
3. Double-click `install.cmd`. It auto-detects Steam, GOG, and Epic installs, sets up the required mod loaders if they are missing, and deploys the mod.
4. Configure your tracker to send OpenTrack UDP to `127.0.0.1:4242` (see [Setting Up OpenTrack](#setting-up-opentrack)).
5. Launch Cyberpunk 2077.

The installer never downloads anything: Cyber Engine Tweaks, RED4ext, and TweakXL are all bundled in the ZIP. If you already have one of them it is left alone, unless it is older than the bundled copy, in which case the installer says so and asks whether to replace it. Answering no is fine if you are deliberately holding an older game build.

If the installer cannot find your game, point it at the install root explicitly:

```powershell
install.cmd "D:\Games\Cyberpunk 2077"
```

Full command line:

```
install.cmd   [GAME_PATH] [/y] [/upgrade-deps]
uninstall.cmd [GAME_PATH] [/y] [/force]
```

- `/y` never prompts. An out-of-date loader is reported and left alone rather than replaced silently.
- `/upgrade-deps` replaces an out-of-date CET, RED4ext, or TweakXL with the bundled version without asking.

If your game lives somewhere Windows protects (Epic's default `C:\Program Files\Epic Games\` does), the installer will tell you it has no write access. Right-click `install.cmd` and choose **Run as administrator**.

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
4. Centre the headset in SteamVR or OpenTrack while looking forward at the screen. The mod has no centre of its own.

### Webcam Setup

1. Install OpenTrack from its [releases page](https://github.com/opentrack/opentrack/releases).
2. In OpenTrack, set **Tracker** to *Neuralnet Tracker*, which works without IR markers.
3. Select your webcam, run the calibration wizard, and confirm the head model follows your movements in OpenTrack's preview.
4. Set Output as above and click **Start**.

### Phone App Setup

Phone trackers generally all speak OpenTrack UDP, but they differ in how much filtering they do on the phone, and that is what decides how you should wire them up:

- **Direct send**: point the app at your PC's LAN IP on port `4242`. This only works if the app filters its own signal on-device. A raw or lightly filtered feed sent straight to the mod will jitter, because the mod's smoothing is sized to take the edge off a clean signal rather than to rescue a noisy one. [Headcam](https://headcam.app) (my free tracking app) filters on-device, so can send directly.

  Not sure about yours? Try direct first. Hold your head still and watch the view: if it drifts or shakes, switch to the OpenTrack route below.
- **Via OpenTrack**: have the phone send to OpenTrack on a different port (for example 5252), then OpenTrack's Output forwards to `127.0.0.1:4242`. Apps that send a raw or lightly filtered signal need this route so OpenTrack's filters and curve mapping can clean the feed up first.

The mod's own smoothing and deadzone apply either way, but they are sized to take the edge off an already clean signal, not to rescue a noisy one.

## Controls

Two equivalent binding sets, so use whichever your keyboard has. Both sets are always active: a nav-cluster key and its chord fire the same action, and pressing either triggers it once.

| Action              | Nav-cluster | Chord           |
|---------------------|-------------|-----------------|
| Toggle tracking     | `End`       | `Ctrl+Shift+Y`  |
| Cycle tracking mode | `Page Up`   | `Ctrl+Shift+G`  |
| Toggle yaw mode     | `Page Down` | `Ctrl+Shift+H`  |
| Cycle ADS mode      | `Home`      | `Ctrl+Shift+T`  |

`Page Up` / `Ctrl+Shift+G` cycles tracking mode:

1. Normal head-tracked gameplay
2. Positional tracking disabled, rotational tracking enabled
3. Rotational tracking disabled, positional tracking enabled
4. Back to normal

`Home` / `Ctrl+Shift+T` cycles what happens when you aim down sights:

1. **Sights on the reticle** (default) - tracking pauses and the game takes the camera back, so the view swings onto the point the reticle was marking. Your shot lands where you had it lined up.
2. **Sights on screen centre** - tracking pauses with the view held exactly where your head left it, and the sights line up on whatever is at the centre of the screen. Aim moves, the view does not.
3. **Head tracking stays live** - nothing pauses. You keep looking around while the sights are up, and the reticle keeps marking where the rounds go.

The choice is saved, so it survives a restart.

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
  "local_smoothing": 0.0,
  "remote_smoothing": 0.15,

  "clamp_yaw": 120.0,
  "clamp_pitch": 80.0,
  "clamp_roll": 45.0,

  "deadzone_yaw": 0.5,
  "deadzone_pitch": 0.5,
  "deadzone_roll": 1.0,

  "crosshair_enabled": true,
  "crosshair_fov_degrees": 84.0,
  "crosshair_lead_factor": 0.0,

  "position_enabled": true,
  "position_sens_x": 1.0,
  "position_sens_y": 1.0,
  "position_sens_z": 1.0,
  "position_limit_x": 0.30,
  "position_limit_y_up": 0.20,
  "position_limit_y_down": 0.05,
  "position_limit_z_fwd": 0.40,
  "position_limit_z_back": 0.10,

  "yaw_mode": "world",
  "ads_mode": "reticle"
}
```

JSON has no comment syntax, so the settings worth touching are described here instead:

- `sensitivity_*` (0.1 to 5.0): per-axis rotation multiplier. Raise pitch if you want more vertical range from less head movement.
- `local_smoothing` (0.0 to 1.0, default 0.0): smoothing applied when the tracker runs on this machine (loopback). 0 = no smoothing, 1 = heavy.
- `remote_smoothing` (0.0 to 1.0, default 0.15): smoothing applied when the tracker is a remote device on the network. 0 = no smoothing, 1 = heavy.
  The mod picks between the two from the source address of each tracking packet, so switching from a local OpenTrack instance to a phone on WiFi swaps the value with no restart. Both cover rotation and position, so there is no separate position smoothing setting. Local defaults to zero because a same-machine tracker is already stable and any smoothing there is pure added latency.
- `clamp_*` (degrees): rotation caps, so head rotation cannot fight the aim system.
- `crosshair_*`: parallax-correct reticle overlay. Set `crosshair_fov_degrees` to your in-game FOV so the marker tracks the true aim point at extreme head angles.
- `position_*`: 6DOF translation. Sensitivities are per-axis multipliers, limits are in meters.
- `deadzone_yaw` / `deadzone_pitch` / `deadzone_roll`: degrees of head movement ignored around centre, to stop tracker noise drifting the view while you hold still. Roll defaults higher than the other two because head-roll noise is the usual cause of the view slowly rolling on its own; raise it if you still see that.
- `ads_mode`: what aiming down sights does to the view. `"reticle"` (default) stands tracking down, so the sights swing onto the point the reticle was marking. `"center"` holds the view where your head left it and puts the sights on whatever is at the centre of the screen. `"tracked"` leaves head tracking running through the aim. Cycled live with `Home` / `Ctrl+Shift+T`, and persisted.
- `yaw_mode`: `"world"` is horizon-locked yaw, so head yaw always swings around world vertical no matter how far the view has pitched. `"local"` pivots around the camera's current up-axis instead, which tilts with mouse pitch. Toggle live with `Page Down` / `Ctrl+Shift+H`, but note this one is **not persisted**: every launch starts back in `"world"`, so the toggle lasts for the session only.

## Troubleshooting

**Reticle shimmers when turning your head, with frame generation on.**
- The reticle is an overlay drawn once per rendered frame. Frame generation creates extra frames by interpolating between rendered ones, and it has no motion vectors for an injected overlay, so anything that moves quickly across the screen picks up a slight shimmer. That part is inherent to overlays under frame generation and cannot be fixed from the mod side.
- The mod smooths the live FOV it projects with, which removes the avoidable share of the wobble. If it still bothers you, turning frame generation off removes it entirely.

**Head tracking works but gunfire still follows your head after a game patch.**
- The native plugin pins a few hooks to addresses derived from one specific game build. On a build it does not recognise it stays dormant rather than writing those hooks into whatever moved into their place, which would crash the game.
- `<Cyberpunk 2077>\red4ext\logs\HeadTrackingAim.log` says which case you are in. `[BuildRegistry] matched build profile ...` means the build is recognised. Otherwise it prints the running EXE's fingerprint, every build it knows about, and whether your game is newer than the mod (check the releases page for an update), older (let your store finish updating), or repacked.
- Head tracking itself, the camera, and projectile aim decoupling do not depend on those hooks and keep working either way.

**Which log to send when you report a problem.**
- `<Cyberpunk 2077>\red4ext\logs\HeadTrackingAim.log`. It starts fresh every time the game launches, and the launch before it is kept alongside as `HeadTrackingAim.prev.log`. If the game crashed and you have already restarted it, the session you want is the `.prev` one.
- The Lua side prints to the CET console, saved to `bin\x64\plugins\cyber_engine_tweaks\scripting.log`.

**Mod not loading.**
- Confirm CET opens in-game (default key `~`). If it does not, fix CET first.
- An out-of-date CET or RED4ext will not initialise on a current game build, and takes every mod under it down with it. Re-run `install.cmd /upgrade-deps` to replace them with the bundled versions.
- Check `<Cyberpunk 2077>\red4ext\logs\HeadTrackingAim.log` for `[HeadTrackingAim] UDP receiver listening on port 4242`. If the file is not there at all, RED4ext did not load the native plugin, and `red4ext.log` in the same folder says why. Reinstall RED4ext and re-run `install.cmd`.
- Open the CET console and look for `[HeadTracking]` messages from the Lua side.

**No tracking response.**
- Make sure OpenTrack (or your phone app) is sending UDP to `127.0.0.1:4242` and has been **Start**ed.
- Allow UDP 4242 through Windows Firewall.
- If the tracker runs on a different machine, send to your gaming PC's LAN IP, not `127.0.0.1`.
- If `HeadTrackingAim.log` shows `Failed to bind UDP port 4242`, another app is holding the port (a second head-tracking mod, or a leftover game process). Close it and tracking comes back on its own within about half a second. The receiver retries the port every 500ms in the background and logs `Bound UDP port 4242` when it gets in, so no game restart is needed.

**Jittery or unstable tracking.**
- Raise the smoothing parameter that matches your tracker: `remote_smoothing` for a phone or other device on the network, `local_smoothing` for a tracker running on this PC. 0.3 to 0.5 is a heavy but usable setting.
- If a phone tracker is sending straight to port `4242` and it does not filter heavily on-device, relay it through OpenTrack with a low-pass filter instead.
- High-FPS displays show micro-jitter more readily. There is no internal minimum any more, so if a local tracker looks jittery at the default `local_smoothing` of 0.0, raise it.

**Head tracking stops while aiming down sights.**
- That is the default, and it is deliberate. Aiming down sights puts the camera on the weapon's sight line and that sight picture is the aim, so head rotation would swing the view off the sights while the rounds kept going where the sights point. Tracking pauses for as long as the sights are up and resumes when you lower the weapon.
- Press `Home` / `Ctrl+Shift+T` to cycle to the other two behaviours. The third one keeps tracking live through the aim.
- Your view is the same before and after, so repeatedly aiming will not walk it around.

**Wrong rotation axis (camera moves the wrong way).**
- Invert the offending axis in OpenTrack under **Output > Mapping** rather than in the mod. The mod has no inversion setting on purpose.
- For yaw that feels off only when looking up or down, toggle yaw mode with `Page Down` / `Ctrl+Shift+H`.

## Updating

Download the new release ZIP and run `install.cmd` again. Your `config.json` is preserved.

## Uninstalling

Run `uninstall.cmd`. This removes the mod's Lua tree under `bin\x64\plugins\cyber_engine_tweaks\mods\HeadTracking\`, the `HeadTrackingAim.dll` native plugin, and the TweakXL yaml under `r6\tweaks\`, which restores stock hitscan gunfire.

It also takes the mod's three hotkeys back out of CET's shared `bindings.json`, leaving every other mod's bindings untouched.

Cyber Engine Tweaks, RED4ext, and TweakXL are shared modding frameworks that your other mods likely depend on, so they are left in place even when you pass `uninstall.cmd /force`. Remove them by hand if you want the game fully vanilla.

## Building from Source

Prerequisites: [pixi](https://pixi.sh), Visual Studio 2019 or 2022 with the Desktop development with C++ workload, and a local Cyberpunk 2077 install.

```powershell
git clone --recurse-submodules https://github.com/itsloopyo/cyberpunk-2077-headtracking.git
cd cyberpunk-2077-headtracking
pixi run install    # build the native plugin and deploy to the detected game install
pixi run package    # produce installer and Nexus ZIPs in release/
```

## Community and Support

- [Discord](https://discord.com/invite/dxyZdyFNT9) - setup help, bug reports, and new-release announcements
- [Lopari](https://lopari.app) - my free launcher for Windows with one-click install and launch of my mods
- [Headcam](https://headcam.app) - my free phone head-tracker app

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
