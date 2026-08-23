# Third-Party Notices

This mod is licensed under the MIT License, Copyright (c) 2026 itsloopyo - see [LICENSE](LICENSE). The components below are third-party and keep their own licenses.

## Cyber Engine Tweaks

- **Version:** v1.37.1
- **License:** MIT
- **Upstream:** https://github.com/maximegmd/CyberEngineTweaks
- **Usage:** Hosts the Lua mod and provides game scripting APIs (`Game`, `Observe`, `Override`, `ImGui`, `registerHotkey`).
- **Bundled:** yes - `vendor/cet/cet.zip`, bundled in the release ZIP and used as the install-time source.

---

## RED4ext

- **Version:** v1.30.0
- **License:** MIT
- **Upstream:** https://github.com/WopsS/RED4ext
- **Usage:** Loader for the native C++ plugin, which hosts the UDP receiver and registers the mod's script functions.
- **Bundled:** yes - `vendor/red4ext/red4ext.zip`, bundled in the release ZIP and used as the install-time source.

---

## TweakXL

- **Version:** v1.11.4 (commit `f8da6be4fb7b8340d5744d822a85de1400f2cafb`)
- **License:** MIT
- **Upstream:** https://github.com/psiberx/cp2077-tweak-xl
- **Usage:** Applies the TweakDB changes in `r6/tweaks/` that switch player gunfire from hitscan to projectile attacks, which is what makes look/aim decoupling possible.
- **Bundled:** yes - `vendor/tweakxl/tweakxl.zip`, bundled in the release ZIP and used as the install-time source.

---

## RED4ext.SDK

- **Version:** git submodule at `native/deps/RED4ext.SDK`
- **License:** MIT
- **Upstream:** https://github.com/WopsS/RED4ext.SDK
- **Usage:** C++ SDK headers used to build the native RED4ext plugin. Headers only; no SDK binaries ship in release ZIPs.
- **Bundled:** no.

---

## OpenTrack

- **Version:** runtime, user-installed
- **License:** ISC
- **Upstream:** https://github.com/opentrack/opentrack
- **Usage:** External head-tracking application; sends UDP packets (6-double format) that the native plugin consumes on port 4242. Protocol interop only; no OpenTrack code is bundled or linked.
- **Bundled:** no.

---

## Dear ImGui

- **Version:** consumed transitively via the CET runtime
- **License:** MIT
- **Upstream:** https://github.com/ocornut/imgui
- **Usage:** Immediate-mode GUI used for the offset crosshair overlay, accessed through CET's exposed `ImGui` API.
- **Bundled:** no.

---

## Components inside the vendored loader ZIPs

The three vendored ZIPs are unmodified upstream release archives, byte-identical to the
assets published on each project's releases page (the SHA-256 of each is recorded in
`vendor/<loader>/README.md`). Each upstream archive carries its own third-party
components and the notices covering them, which travel with it:

- `vendor/cet/cet.zip` - Cyber Engine Tweaks ships the Noto Sans font family and
  Material Design Icons (both SIL Open Font License 1.1), and rxi's `json.lua` (MIT).
  Their notices are inside the archive at `bin/x64/plugins/cyber_engine_tweaks/ThirdParty_LICENSES`
  and `.../scripts/json/LICENSE`, and are extracted alongside the loader on install.
- `vendor/red4ext/red4ext.zip` - carries `red4ext/THIRD_PARTY_LICENSES.txt`.
- `vendor/tweakxl/tweakxl.zip` - carries `red4ext/plugins/TweakXL/THIRD_PARTY_LICENSES`.

We do not repackage, recompile or alter any of these archives, so the upstream notices
remain the authoritative record for everything inside them.

---

## Acknowledgements (no code bundled)

- **GameUI** (`modules/GameUI.lua`) is our own MIT-licensed code. Its module name and the
  shape of its public API follow the convention set by psiberx's GameUI in
  [cp2077-cet-kit](https://github.com/psiberx/cp2077-cet-kit) so that CET mod authors meet
  a familiar surface, but the implementation is written from scratch and shares no code
  with it.

---

## CD PROJEKT RED material

Game assets, engine code, decompiled or disassembled game code, and any other material
belonging to CD PROJEKT RED are not included in this repository. A legitimate copy of
Cyberpunk 2077 is required to use this mod.

The one exception is `assets/readme-clip.gif`, a short clip of the mod running in game.
It is in-game footage of Cyberpunk 2077 and remains the property of CD PROJEKT RED,
reproduced here solely to demonstrate the mod, non-commercially, under CD PROJEKT RED's
fan content guidelines. This project is not affiliated with, endorsed by, or supported by
CD PROJEKT RED. Cyberpunk 2077 and CD PROJEKT RED are trademarks of CD PROJEKT S.A.

The TweakDB record identifiers in `tweaks/` and the module-relative addresses in
`native/src/builds/` are factual observations about the shipped game needed for
interoperability. They contain no game code and no game content.
