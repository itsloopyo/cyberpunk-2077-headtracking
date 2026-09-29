# Cyberpunk 2077 Head Tracking

![Cyberpunk 2077 running with this mod](https://raw.githubusercontent.com/itsloopyo/cyberpunk-2077-headtracking/main/assets/readme-clip.gif)

An unofficial head tracking mod for Cyberpunk 2077 that moves the view with your head while your mouse or controller keeps aiming, driven by a webcam, phone, or any OpenTrack compatible tracker, with no VR headset required.

## Features

- **Decoupled look and aim** - head tracking moves the camera; your mouse or controller still controls aim
- **6DOF positional tracking** - lean into corners and peek around cover with your head position
- **Works with any OpenTrack compatible tracker** - free options available for PC, iOS and Android

## Gameplay Changes

To decouple your shots from where your head is pointing, the mod switches **player** gunfire to the projectile attacks the game already ships, and uses them permanently rather than only during time dilation. This is a real gameplay change, so it is worth knowing what moves:

- **Rounds have travel time.** At any normal engagement distance you will not notice this, but at long range you lead a moving target slightly.
- **Bullets are physical objects.** They can be seen in flight, and they interact with the world rather than teleporting to the target.
- **Tech weapons are untouched.** Weapons that charge through cover keep their own behavior.
- **NPCs still use hitscan.** Only the player is converted, so there is no added cost from every enemy in a firefight spawning projectiles.
- **Leaning moves your shots while you aim down sights.** With the sights up, a head lean moves your weapon and the point your rounds leave from, so you can lean out and shoot past cover. At the hip a lean moves only the view, as before.
- **23 unique or quest weapons stay on hitscan** (MA70, AirDrop variants, Nova Doom Doom, and Saratoga Maelstrom among them) and will not decouple.

Everything is applied through TweakXL, so removing the mod restores stock behavior completely.

## Known Issues

**A few weapons still shoot hitscan.** 23 unique and quest weapons (MA70, the AirDrop variants, Nova Doom Doom and Saratoga Maelstrom among them) use their own attack records and are not converted, so aim stays coupled to your head on those. Every standard weapon is covered.

## Requirements

- [Cyberpunk 2077](https://store.steampowered.com/app/1091500/Cyberpunk_2077/) v2.x (Steam, GOG, or Epic).
- An OpenTrack-compatible head tracker: [OpenTrack](https://github.com/opentrack/opentrack) with a webcam or VR headset, or a phone app that speaks the OpenTrack UDP protocol (see [Phone](#phone) for which apps can send straight to the mod and which need OpenTrack in the chain).
- Windows 10 or 11, 64-bit.

## Installation

### Lopari

Download [Lopari](https://lopari.app), choose **Cyberpunk 2077**, and click
**Play with head tracking**.

### Standalone Installer

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

The mod listens for OpenTrack pose data on UDP port `4242`, on every network
interface. One datagram is six little-endian 64-bit floats in the order
`x, y, z, yaw, pitch, roll`: position in centimetres, rotation in degrees, 48
bytes in total. Anything that sends that to that port drives the view.
OpenTrack's **UDP over network** output sends exactly this, and the steps below
set it up.

1. Install [OpenTrack](https://github.com/opentrack/opentrack/releases).
2. Pick a tracker under **Input**, using the notes below.
3. Set **Output** to **UDP over network**, host `127.0.0.1`, port `4242`.
4. Press **Start**. Tracking and the game can start in either order.

### Webcam

OpenTrack ships a `neuralnet tracker` input that reads a plain webcam. Select it
under **Input**, pick your camera in its settings, and use the output settings
above. How well it tracks depends on your camera and your lighting, so try it
before buying anything.

### Phone

A phone app can reach the mod directly, with no OpenTrack on the PC, if it sends
the datagram described above. Point it at this PC's IP address (run `ipconfig`
to find it) on port `4242`. Not every phone tracker speaks this protocol, so
check yours for an OpenTrack or UDP output option first. [Headcam](https://headcam.app)
sends it, and I wrote it so decent tracking is free for anyone who already owns
a phone.

Sending direct works when the app filters its own signal on the device. The
mod's smoothing is sized to take the edge off a clean signal rather than to
rescue a noisy one, so a raw feed sent direct will jitter. If it does, point the
app at OpenTrack's **UDP over network** *input* on some other port, say 5252,
and let OpenTrack's filters and curves clean it up before its output forwards to
`127.0.0.1:4242`.

Anything arriving from outside `127.0.0.0/8` counts as a remote connection and
is smoothed with `RemoteSmoothing` rather than `LocalSmoothing`. That includes a
tracker on this very PC that sends to the machine's own LAN address, because the
mod reads the source address and not the machine.

### Headset or other hardware

If your device has an OpenTrack input driver, select it under **Input** and use
the same output settings. OpenTrack's own **Input** list is the authority on
what it can read; the mod only ever sees what OpenTrack sends.

### Centring

Centring belongs to your tracker. The mod subtracts no centre of its own: it
applies the pose it receives exactly as it arrives, so a stream of zeros holds
the view where the game itself puts it. Press the centre control in your tracker
(OpenTrack's **Center** bind, or the CENTER button in Headcam) and the tracker
zeroes its own output, which leaves the view centred with the mod doing nothing.

That is why there is no centre hotkey here and nothing to re-centre in game. Two
centres in series would drift apart, because each side re-centres at moments the
other cannot see, and you would end up pressing twice to centre once. If the
view sits off to one side, centre it in the tracker.

## Controls

These are the default bindings. Change the hotkey rows in `CameraUnlock.ini` or `Defaults.ini` to remap them.

Two equivalent binding sets, so use whichever your keyboard has. Both sets are always active: a nav-cluster key and its chord fire the same action, and pressing either triggers it once.

| Action                | Nav-cluster | Chord           |
|-----------------------|-------------|-----------------|
| Toggle tracking       | `End`       | `Ctrl+Shift+Y`  |
| Cycle tracking mode   | `Page Up`   | `Ctrl+Shift+G`  |
| Toggle yaw mode       | `Page Down` | `Ctrl+Shift+H`  |
| Toggle true free look | `Insert`    | `Ctrl+Shift+U`  |

`Page Up` / `Ctrl+Shift+G` cycles tracking mode:

1. Normal head-tracked gameplay
2. Positional tracking disabled, rotational tracking enabled
3. Rotational tracking disabled, positional tracking enabled
4. Back to normal

### Aiming down sights

Head tracking stays on while you aim. The weapon stays where your mouse or controller points it, so with your head turned it sits off to one side with its sights still lined up, and your rounds land where those sights point.

Leaning carries on through the aim. As the sights come up, your arms and weapon move with your head, so the sights stay in front of your eye, and your rounds leave from where your eye is. Lean round a corner with the sights up and you can hit what you can see from there. Handing the lean from the camera to the weapon does not move the view. Head movement, the lean included, is scaled to the zoom so a scope does not magnify it, which means a high-magnification scope leans less.

By default leaning never takes your eye off the sights. `Insert` / `Ctrl+Shift+U` switches to **true free look**: the weapon stays put and your head moves freely around it, so to see down the sights you have to put your head behind them, as you would in VR. It is hard, and it is off by default. The mod saves the mode you pick, so it holds the next time you start the game.

With your head turned, the centre of a scope still shows what the round will hit. The game draws the weapon more magnified than the world while a scope is up, which would otherwise swing the scope further across the screen than the scene behind it, so the mod turns the weapon back by the difference.

A lean is checked against the level with a 10 cm sphere around the eye, so it stops about 10 cm short of walls, door frames, table edges and other level geometry instead of putting the view inside them.

A scope's target indicator lights for what the scope is pointed at, not for what your head is facing.

## In vehicles

First-person driving tracks your head exactly like being on foot.

The outside chase camera tracks your head too. Turn it off with "Chase Camera Tracking" in the settings panel, or `ChaseCameraTracking` in `CameraUnlock.ini`. Two rough edges to know about:

- The near scene follows your head; the distant scene stays fixed on the screen. Third-person driving renders through more than one view, and only one of them currently carries the head rotation.
- The game's camera motion blur smears the whole world, because it works out how fast static geometry is moving from a camera that has not been rotated. **Turn Motion Blur off** in Graphics.

6DOF translation reaches the chase camera too, by a different route. On foot the offset goes into the first-person camera's local position; here it is published to the native plugin, which shifts the chase camera's own world position by it, turned by the camera's orientation from before the head rotation was composed in, so leaning goes with the vehicle rather than with where your head is pointing. The lean there gets the same 10 cm check against the level, from the chase camera's own position. `position_enabled` switches translation off for both cameras.

Head yaw there pans and tilts about the camera's own axes, so it behaves like local yaw mode whichever yaw mode you have selected.

## Configuration

<!-- cameraunlock:config -->
The mod reads its settings from `bin\x64\plugins\cyber_engine_tweaks\mods\HeadTracking\CameraUnlock.ini` in the game folder, and creates the file when it starts and finds none. Edit it with any text editor.

A setting set to `default` takes its value from `Defaults.ini`, which every head tracking mod that keeps its settings in `CameraUnlock.ini` reads. Head tracking mods that keep their settings in another file do not read it. Changing a setting in `Defaults.ini` changes it in every game that has it set to `default`. Writing a value in place of `default` changes that setting for this game only. When the mod saves a setting that a hotkey changed in game, it writes the new value in place of `default`, so that setting no longer follows `Defaults.ini` in this game until you set it to `default` again.

`Defaults.ini` is `%AppData%\CameraUnlock\Defaults.ini` on Windows; `$XDG_CONFIG_HOME/CameraUnlock/Defaults.ini` on Linux, or `~/.config/CameraUnlock/Defaults.ini` where `XDG_CONFIG_HOME` is not set, under Wine and Proton too; and `~/Library/Application Support/CameraUnlock/Defaults.ini` on macOS. The mod's log, where it writes one, names the file it read.

When the mod starts and finds no `Defaults.ini`, it creates one holding the built-in values, unless Windows runs the game as a packaged app. The mod never changes `Defaults.ini` after that. Edit it with any text editor.

The built-in value of each setting set to `default` below:

- `EnableOnStartup=true`
- `WorldSpaceYaw=true`
- `RotationEnabled=true`
- `LocalSmoothing=0.0`
- `RemoteSmoothing=0.15`
- `PositionEnabled=true`
- `TrueFreeLook=false`
- `PositionLimitX=0.3`
- `PositionLimitY=0.2`
- `PositionLimitYDown=0.2`
- `PositionLimitZ=0.4`
- `PositionLimitZBack=0.1`
- `ToggleKey=End, Ctrl+Shift+Y`
- `CycleTrackingModeKey=PageUp, Ctrl+Shift+G`
- `YawModeKey=PageDown, Ctrl+Shift+H`
- `TrueFreeLookKey=Insert, Ctrl+Shift+U`

With every setting at its default, the file reads:

```ini
; Cyberpunk 2077 head tracking settings.
; Comments start with ; and go on their own line. Text after a value is part of the value.
; Hotkeys are key names such as End, PageUp or Ctrl+Shift+Y. Separate several with commas; leave empty for none.
; A setting set to default takes its value from Defaults.ini, which every head tracking mod
; that keeps its settings in CameraUnlock.ini reads: %AppData%\CameraUnlock\Defaults.ini on
; Windows, $XDG_CONFIG_HOME/CameraUnlock/Defaults.ini (normally ~/.config/CameraUnlock) on
; Linux, under Wine and Proton too, and ~/Library/Application Support/CameraUnlock/Defaults.ini
; on macOS. The log names the file it read. Change a setting in Defaults.ini to change it in
; every game that has it set to default, or write a value here instead of default to change it
; for this game only.

[CameraUnlock]
; Written by the mod. Leave this section in place.
ConfigFormat=1

[General]
; true: head tracking is on when the game starts. ToggleKey turns it on and off.
EnableOnStartup=default
; true: yaw turns around the world's up axis. false: around the camera's own up axis.
WorldSpaceYaw=default
; true: turning your head turns the view.
; Tracking mode at startup, with PositionEnabled. The mode hotkey changes both.
RotationEnabled=default

[Smoothing]
; Smoothing when the tracker runs on this PC. 0 is the least, 1 the most.
LocalSmoothing=default
; Smoothing when the tracker is another device on the network, such as a phone.
; 0 is the least, 1 the most.
RemoteSmoothing=default

[Position]
; true: moving your head moves the view.
; Tracking mode at startup, with RotationEnabled. The mode hotkey changes both.
PositionEnabled=default
; false: while you aim down the sights, leaning keeps your eye on the sights.
; true: the weapon stays put and your head moves freely around it (true free look).
TrueFreeLook=default
; How far, in metres, leaning left or right can move the view.
PositionLimitX=default
; How far, in metres, raising your head can move the view.
PositionLimitY=default
; How far, in metres, lowering your head can move the view.
PositionLimitYDown=default
; How far, in metres, leaning forward can move the view.
PositionLimitZ=default
; How far, in metres, leaning back can move the view.
PositionLimitZBack=default

[Hotkeys]
; Turns head tracking on and off.
ToggleKey=default
; Changes the tracking mode: rotation and position, rotation only, position only.
CycleTrackingModeKey=default
; Switches yaw between the world's up axis and the camera's own (WorldSpaceYaw).
YawModeKey=default
; Switches between keeping your eye on the sights and true free look (TrueFreeLook).
TrueFreeLookKey=default

[Camera]
; Maximum head rotation in degrees, relative to the aim.
MaxYawDegrees=120.0
MaxPitchDegrees=80.0
MaxRollDegrees=45.0
; Apply head tracking to the third-person vehicle camera.
ChaseCameraTracking=true
```
<!-- /cameraunlock:config -->

[Native Settings UI](https://www.nexusmods.com/cyberpunk2077/mods/3518) adds tracking mode, yaw mode, true free look, smoothing, camera limits and chase-camera tracking to the game's Settings menu. Changes apply immediately and are saved for this game. The master switch lasts for the session; EnableOnStartup controls the next launch. Restart the game after editing either INI file by hand.

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
- High-FPS displays show micro-jitter more readily. `local_smoothing` defaults to 0.0, so if a local tracker looks jittery, raise it.

**The weapon is off to one side when I aim down sights.**
- Your head is turned: the weapon stays on your aim and you are looking past it. Turn back to it, or move your aim to where you are looking.

**I can't see down the sights, they are misaligned.**
- You are in true free look and your head is leaned off them. Move your head back behind them, or press `Insert` / `Ctrl+Shift+U` to return to sights locked.

**Wrong rotation axis (camera moves the wrong way).**
- Invert the offending axis in OpenTrack under **Output > Mapping** rather than in the mod. The mod has no inversion setting on purpose.
- For yaw that feels off only when looking up or down, toggle yaw mode with `Page Down` / `Ctrl+Shift+H`.

## Updating

Download the new release ZIP and run `install.cmd` again. Your settings are preserved.

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

## Community & Support

- Discord: [Loop's Head Tracking Hangout](https://discord.com/invite/dxyZdyFNT9) - setup help, bug reports, and new-release announcements
- [Lopari](https://lopari.app) - free Windows launcher with one-click install and launch for the released head-tracking mods
- [Headcam](https://headcam.app) - free app that turns your iPhone or Android phone into the head tracker

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

Cyberpunk 2077 and CD PROJEKT RED are trademarks of CD PROJEKT S.A. This repository contains no game assets and no game or engine code of any kind, and a legitimate copy of the game is required to use the mod. The clip at the top of this page is in-game footage that remains the property of CD PROJEKT RED, shown non-commercially to demonstrate the mod under their fan content guidelines. Full attribution for every third-party component is in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
