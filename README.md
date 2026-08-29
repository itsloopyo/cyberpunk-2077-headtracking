# Cyberpunk 2077 Head Tracking

![Cyberpunk 2077 running with this mod](https://raw.githubusercontent.com/itsloopyo/cyberpunk-2077-headtracking/main/assets/readme-clip.gif)

An unofficial head tracking mod for Cyberpunk 2077 that moves the view with your head while your mouse or controller keeps aiming, driven by a webcam, phone, or any OpenTrack compatible tracker, with no VR headset required.

## Features

- **Decoupled look and aim** - head tracking moves the camera; your mouse or controller still controls aim
- **6DOF positional tracking** - lean into corners and peek around cover with your head position
- **Three ways to aim down sights** - raising the sights always swings the view onto the point the reticle was marking. After that, pick one: head tracking off for the rest of the aim (the default), on with a marker showing where your rounds will land, or on with no marker. Cycled in game with `Insert`

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

The mod's connection-specific smoothing applies either way. Configure sensitivity, deadzones, response curves, and tracker-axis options in OpenTrack or your tracking app; the mod consumes its output at 1:1 scale.

## Controls

Two equivalent binding sets, so use whichever your keyboard has. Both sets are always active: a nav-cluster key and its chord fire the same action, and pressing either triggers it once.

| Action              | Nav-cluster | Chord           |
|---------------------|-------------|-----------------|
| Toggle tracking     | `End`       | `Ctrl+Shift+Y`  |
| Cycle tracking mode | `Page Up`   | `Ctrl+Shift+G`  |
| Toggle yaw mode     | `Page Down` | `Ctrl+Shift+H`  |
| Cycle ADS mode      | `Insert`    | `Ctrl+Shift+U`  |

`Insert` avoids MCM's `Home` shortcut. The `Ctrl+Shift+U` alternative is unchanged.

`Page Up` / `Ctrl+Shift+G` cycles tracking mode:

1. Normal head-tracked gameplay
2. Positional tracking disabled, rotational tracking enabled
3. Rotational tracking disabled, positional tracking enabled
4. Back to normal

`Insert` / `Ctrl+Shift+U` cycles what happens when you aim down sights. All three start the same way - raising the sights swings the view onto the point the reticle was marking, so your shot lands where you had it lined up - and they differ in what happens for the rest of the aim:

1. **Tracking paused** (default) - the game keeps the camera for as long as the sights are up. The sight picture is exactly the game's, and head movement does nothing until you lower the weapon.
2. **Tracking on, with an aim marker** - head tracking carries on from the snapped position, and a small white crosshair is drawn wherever your rounds will actually land. This white marker is authoritative, including with scoped weapons. A scope's built-in reticle is only accurate while your eye is exactly aligned with the optic, so the two reticles separate when head tracking moves your view off that sight line.
3. **Tracking on, no aim marker** - the same as 2 without the marker, for a cleaner screen when you are happy reading the sights themselves.

The choice is saved, so it survives a restart. Pressing the key shows a toast naming the mode you switched to.

## In vehicles

First-person driving tracks your head exactly like being on foot.

The outside chase camera tracks your head too. Turn it off with "Chase Camera Tracking" in the settings panel, or `chase_camera_tracking` in `config.json`. Two rough edges to know about:

- The near scene follows your head; the distant scene stays fixed on the screen. Third-person driving renders through more than one view, and only one of them currently carries the head rotation.
- The game's camera motion blur smears the whole world, because it works out how fast static geometry is moving from a camera that has not been rotated. **Turn Motion Blur off** in Graphics.

Rotation only, no leaning: 6DOF translation moves the first-person camera and the chase camera does not read it. Head yaw there pans and tilts about the camera's own axes, so it behaves like local yaw mode whichever yaw mode you have selected.

## Configuration

The mod writes its config to:

```
<Cyberpunk 2077>\bin\x64\plugins\cyber_engine_tweaks\mods\HeadTracking\config.json
```

Edit it directly, or configure the mod in game if you have a settings framework installed. The defaults below are what the mod ships with:

- [Native Settings UI](https://www.nexusmods.com/cyberpunk2077/mods/3518) puts every option below (except the reverse-engineering diagnostic) into the game's own Settings menu, controller included. Optional: without it the mod runs exactly the same and you edit `config.json` by hand.

Native Settings is the only framework this mod registers with. If you use a different settings front-end, whether it picks this mod up is down to whether that front-end reads Native Settings' registry - nothing extra is needed from here either way.


```json
{
  "enabled": true,

  "local_smoothing": 0.0,
  "remote_smoothing": 0.15,

  "clamp_yaw": 120.0,
  "clamp_pitch": 80.0,
  "clamp_roll": 45.0,

  "crosshair_enabled": true,

  "position_enabled": true,
  "position_limit_x": 0.30,
  "position_limit_y_up": 0.20,
  "position_limit_y_down": 0.05,
  "position_limit_z_fwd": 0.40,
  "position_limit_z_back": 0.10,

  "yaw_mode": "world",
  "ads_mode": "paused",

  "saved_tracking_mode": "both"
}
```

JSON has no comment syntax, so the settings worth touching are described here instead. Ranges below are what the file accepts; the in-game sliders deliberately cover a narrower band, so a value you type into the file can sit outside what the slider can reach.

- `local_smoothing` (0.0 to 1.0, default 0.0): smoothing applied when the tracker runs on this machine (loopback). 0 = no smoothing, 1 = heavy.
- `remote_smoothing` (0.0 to 1.0, default 0.15): smoothing applied when the tracker is a remote device on the network. 0 = no smoothing, 1 = heavy.
  The mod picks between the two from the source address of each tracking packet, so switching from a local OpenTrack instance to a phone on WiFi swaps the value with no restart. Both cover rotation and position, so there is no separate position smoothing setting. Local defaults to zero because a same-machine tracker is already stable and any smoothing there is pure added latency.
- `clamp_*` (degrees): rotation caps, so head rotation cannot fight the aim system.
- `crosshair_enabled`: moves the game's own reticle to the true aim point during normal play. The ADS marker is separate and remains available in `ads_mode: "marker"`. Both use Cyberpunk's live camera projection, including the exact scope projection, rather than an estimated field of view.
- `position_enabled` and `position_limit_*`: enable 6DOF translation and set Cyberpunk-specific camera travel limits in metres. Positional sensitivity belongs in the tracker.
- `saved_tracking_mode`: not a setting - it is where the mod remembers which tracking mode to restore when tracking is switched back on, whether that is you pressing `End` or the mod bringing tracking up on the next launch after you quit with it off. Rewritten every time you switch tracking off. Leave it alone.
- `ads_mode`: what aiming down sights does. `"paused"` (default) stands tracking down for as long as the sights are up. `"marker"` keeps head tracking live through the aim and draws a white crosshair at the true aim point. Treat that marker as authoritative when a scope's reticle no longer lines up with it. `"tracked"` keeps tracking live with no marker. Cycled live with `Insert` / `Ctrl+Shift+U`, and persisted. The marker's size and colour are fixed; there is no setting for them.
- `yaw_mode`: `"world"` is horizon-locked yaw, so head yaw always swings around world vertical no matter how far the view has pitched. `"local"` pivots around the camera's current up-axis instead, which tilts with mouse pitch. Toggle live with `Page Down` / `Ctrl+Shift+H`. The choice is saved, so it survives a restart.

## Troubleshooting

**Reticle shimmers when turning your head, with frame generation on.**
- The reticle is an overlay drawn once per rendered frame. Frame generation creates extra frames by interpolating between rendered ones, and it has no motion vectors for an injected overlay, so anything that moves quickly across the screen picks up a slight shimmer. That part is inherent to overlays under frame generation and cannot be fixed from the mod side.
- The mod smooths the live FOV it projects with, which removes the avoidable share of the wobble. If it still bothers you, turning frame generation off removes it entirely.

**Head tracking works but gunfire still follows your head after a game patch.**
- The native plugin pins a few hooks to addresses derived from one specific game build. On a build it does not recognise it stays dormant rather than writing those hooks into whatever moved into their place, which would crash the game.
- `<Cyberpunk 2077>\bin\x64\HeadTracking.log` says which case you are in. `[BuildRegistry] matched build profile ...` means the build is recognised. Otherwise it prints the running EXE's fingerprint, every build it knows about, and whether your game is newer than the mod (check the releases page for an update), older (let your store finish updating), or repacked.
- Head tracking itself, the camera, and projectile aim decoupling do not depend on those hooks and keep working either way.

**Which log to send when you report a problem.**
- `<Cyberpunk 2077>\bin\x64\HeadTracking.log`. It sits next to `Cyberpunk2077.exe`, starts fresh every time the game launches, and the launch before it is kept alongside as `HeadTracking.prev.log`. Both halves of the mod write to it - the RED4ext plugin and the Cyber Engine Tweaks script. If the game crashed and you have already restarted it, the session you want is the `.prev` one.
- The Lua side writes its startup result into that same `HeadTracking.log`, tagged `[CET]`, and prints everything to the CET console, saved to `bin\x64\plugins\cyber_engine_tweaks\scripting.log`.

**Mod not loading.**
- Confirm CET opens in-game (default key `~`). If it does not, fix CET first.
- An out-of-date CET or RED4ext will not initialise on a current game build, and takes every mod under it down with it. Re-run `install.cmd /upgrade-deps` to replace them with the bundled versions.
- Check `<Cyberpunk 2077>\bin\x64\HeadTracking.log` for `[HeadTrackingAim] UDP receiver listening on port 4242`. If the file is not there at all, RED4ext did not load the native plugin, and `red4ext\logs\red4ext.log` says why. Reinstall RED4ext and re-run `install.cmd`.
- Open the CET console and look for `[HeadTracking]` messages from the Lua side.

**No tracking response.**
- Make sure OpenTrack (or your phone app) is sending UDP to `127.0.0.1:4242` and has been **Start**ed.
- Allow UDP 4242 through Windows Firewall.
- If the tracker runs on a different machine, send to your gaming PC's LAN IP, not `127.0.0.1`.
- If `HeadTracking.log` shows `Failed to bind UDP port 4242`, another app is holding the port (a second head-tracking mod, or a leftover game process). Close it and tracking comes back on its own within about half a second. The receiver retries the port every 500ms in the background and logs `Bound UDP port 4242` when it gets in, so no game restart is needed.

**Jittery or unstable tracking.**
- Raise the smoothing parameter that matches your tracker: `remote_smoothing` for a phone or other device on the network, `local_smoothing` for a tracker running on this PC. 0.3 to 0.5 is a heavy but usable setting.
- If a phone tracker is sending straight to port `4242` and it does not filter heavily on-device, relay it through OpenTrack with a low-pass filter instead.
- High-FPS displays show micro-jitter more readily. There is no internal minimum any more, so if a local tracker looks jittery at the default `local_smoothing` of 0.0, raise it.

**Head tracking stops while aiming down sights.**
- That is the default, and it is deliberate. Aiming down sights puts the camera on the weapon's sight line and that sight picture is the aim, so head rotation would swing the view off the sights while the rounds kept going where the sights point. Tracking pauses for as long as the sights are up and resumes when you lower the weapon.
- Press `Insert` / `Ctrl+Shift+U` if you would rather keep tracking through the aim. The snap onto the aim point still happens; tracking just carries on from there. The first press also turns on an aim marker so you can see where the gun is pointing.
- Your view is the same before and after, so repeatedly aiming will not walk it around.

**The view jumps when I lower the sights, with ADS tracking left on.**
- Expected, and it is the same swing in reverse. Raising the sights takes your head angle out of the view; lowering them puts it back. Hold your head still through the aim and there is nothing to put back.

**No aim marker appears in the mode that should have one.**
- The marker projects through the same machinery that moves the crosshair during normal play, so if that failed to start there is no marker either. Check the CET console at startup for `ADS aim marker initialized`; if instead you see the built-in crosshair driver reporting a failure, that is the cause. The mode still tracks your head through the aim, it just cannot draw.
- The marker hides itself when the aim point falls behind the view, which happens if you turn your head far enough past the weapon.

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
- [cp2077-cet-kit](https://github.com/psiberx/cp2077-cet-kit) by psiberx, whose GameUI module set the API convention our own `modules/GameUI.lua` follows (no code is taken from it).
- [OpenTrack](https://github.com/opentrack/opentrack) for the head-tracking UDP protocol.
- [Dear ImGui](https://github.com/ocornut/imgui) by Omar Cornut, for the in-game crosshair overlay, used through CET.

## Disclaimer

This mod is not affiliated with, endorsed by, or supported by CD PROJEKT RED. It is a single-player utility, so do not use it in any multiplayer or competitive context. Use at your own risk.

Cyberpunk 2077 and CD PROJEKT RED are trademarks of CD PROJEKT S.A. This repository contains no game assets, engine code, or decompiled game code, and a legitimate copy of the game is required to use the mod. The clip at the top of this page is in-game footage that remains the property of CD PROJEKT RED, shown non-commercially to demonstrate the mod under their fan content guidelines. Full attribution for every third-party component is in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
