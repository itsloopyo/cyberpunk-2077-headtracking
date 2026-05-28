# Third-Party Notices

## Cyber Engine Tweaks

- **Version:** runtime, user-installed
- **License:** MIT
- **Upstream:** https://github.com/maximegmd/CyberEngineTweaks
- **Usage:** Hosts the Lua mod and provides game scripting APIs (`Game`, `Observe`, `Override`, `ImGui`, `registerHotkey`).
- **Bundled:** no.

---

## RED4ext

- **Version:** runtime, user-installed
- **License:** MIT
- **Upstream:** https://github.com/WopsS/RED4ext
- **Usage:** Loader for the native C++ plugin and host of the UDP receiver / TCP server.
- **Bundled:** no.

---

## RED4ext.SDK

- **Version:** git submodule at `native/deps/RED4ext.SDK`
- **License:** MIT
- **Upstream:** https://github.com/WopsS/RED4ext.SDK
- **Usage:** C++ SDK headers used to build the native RED4ext plugin. Headers only; no SDK binaries ship in release ZIPs.
- **Bundled:** no.

---

## RedSocket

- **Version:** runtime, user-installed (tested with 0.5.0)
- **License:** MIT
- **Upstream:** https://github.com/rayshader/cp2077-red-socket
- **Usage:** Provides the Lua TCP socket the mod uses to read pose data from the native plugin's TCP server on port 4242.
- **Bundled:** no.

---

## GameUI (cp2077-cet-kit)

- **Version:** vendored at `modules/GameUI.lua` from https://github.com/psiberx/cp2077-cet-kit
- **License:** MIT
- **Upstream:** https://github.com/psiberx/cp2077-cet-kit
- **Usage:** Game state detection (loading, menus, braindance, photo mode, scenes, vehicles).
- **Bundled:** yes (single Lua file vendored into the source tree and shipped in release ZIPs).

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

Game assets, engine code, and any other material belonging to CD PROJEKT RED is not included in this repository. A legitimate copy of Cyberpunk 2077 is required to use this mod.
