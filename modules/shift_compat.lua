-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Shift compatibility
--
-- Shift (Nexus 22340) is a camera mod that writes the same slot we do:
-- SetLocalOrientation on the component GetFPPCameraComponent() returns. That
-- slot holds one absolute quaternion, so the last writer in the frame is the
-- only one the engine sees.
--
-- Shift already tries to be a good citizen - CameraEngine.writeToHardware
-- skips the position and rotation writes while its composited pose is neutral,
-- with a comment saying it is so other mods can own the FPP transform. The
-- conflict only appears once one of its sources contributes a non-zero offset.
-- A saved unarmed preset is the case users hit: with the weapon holstered
-- PresetManager applies it with offsets, so Shift stamps the camera every
-- frame and head tracking dies; drawing a weapon runs the same preset through
-- `onlyUnarmedFOV`, which zeroes the offsets, so Shift goes neutral and
-- tracking works. That is the "head tracking only works with a weapon drawn"
-- report.
--
-- Racing it does not work. CET calls mod update handlers in load order, which
-- is the mod folder name alphabetically, and "HeadTracking" sorts before
-- "Shift". Re-stamping the slot from the native plugin's per-frame tick was
-- measured landing after our own Lua but still before Shift's handler
-- (stamps=2332 intact=1617 in a live session), so it wrote first and Shift
-- still overwrote it.
--
-- So ask instead of fight. Shift's init.lua returns `{ api = ShiftAPI.API }`,
-- which CET hands to other mods through GetMod("Shift"). Its Suppress* calls
-- set runtime overrides that make refreshActivePreset clear the offending
-- sources, which puts Shift's pose back to neutral and stands its camera
-- writes down for real. They are runtime-only: nothing is written to Shift's
-- saved settings, so removing our mod restores its behaviour.

local ShiftCompat = {}

-- Resolved once found. Shift may initialize after us, so the lookup retries.
local api = nil
local looked_up = false

-- Last state pushed to Shift. nil until the first successful push, so the
-- first call always talks to Shift rather than assuming a default.
local applied = nil

-- Frames between GetMod attempts while Shift has not been found. Both mods
-- come up within a second or so of each other; this only exists so the lookup
-- is not run every frame for the whole session on the many installs with no
-- Shift at all.
local LOOKUP_INTERVAL_FRAMES = 120
local frames_until_lookup = 0

--- Resolve Shift's API table, or nil when Shift is not installed.
--- @return table|nil
local function resolve()
    if api then return api end
    if looked_up and frames_until_lookup > 0 then
        frames_until_lookup = frames_until_lookup - 1
        return nil
    end
    looked_up = true
    frames_until_lookup = LOOKUP_INTERVAL_FRAMES

    -- GetMod is CET's cross-mod accessor and returns whatever the other mod's
    -- init.lua returned. Guarded because a mod that errored during init can
    -- leave a partial table behind.
    if type(GetMod) ~= "function" then return nil end
    local ok, mod = pcall(GetMod, "Shift")
    if not ok or type(mod) ~= "table" then return nil end
    if type(mod.api) ~= "table" then return nil end
    if type(mod.api.SuppressWeaponPreset) ~= "function" then return nil end

    api = mod.api
    return api
end

--- Ask Shift to stand its camera sources down (or hand them back).
---
--- The three suppressions are the three routes by which Shift's composited
--- pose becomes non-neutral and it starts stamping the camera:
---   weapon preset    - the weapon and unarmed chains, including ADS
---   vehicle preset   - first-person driving
---   immersive camera - a direct-write consumer that bypasses the compositor
--- ResetCamera clears the sources that are already active, so the change lands
--- now instead of at the next weapon or vehicle transition.
--- @param suppress boolean
--- @param log function|nil Called with a one-line message on a state change
--- @return boolean true when Shift is present and now in the requested state
function ShiftCompat.apply(suppress, log)
    local a = resolve()
    if not a then return false end

    suppress = suppress and true or false
    if applied == suppress then return true end

    a.SuppressWeaponPreset(suppress)
    a.SuppressVehiclePreset(suppress)
    a.SuppressImmersiveCamera(suppress)
    a.ResetCamera(0)
    applied = suppress

    if log then
        if suppress then
            log("[HeadTracking] Shift detected - asked it to stand its camera down " ..
                "(weapon, vehicle and immersive presets). Both mods write the same " ..
                "camera slot and Shift's writes land after ours, so leaving them on " ..
                "stops head tracking. Turn head tracking off to hand them back.")
        else
            log("[HeadTracking] handed Shift's camera presets back")
        end
    end
    return true
end

--- Is Shift installed and talking to us?
--- @return boolean
function ShiftCompat.isPresent()
    return api ~= nil
end

--- Drop our overrides on shutdown. Separate from apply() because it must run
--- even when nothing was ever suppressed, and must not be skipped by the
--- no-change early return.
--- @param log function|nil
function ShiftCompat.release(log)
    if not api or applied ~= true then return end
    api.SuppressWeaponPreset(false)
    api.SuppressVehiclePreset(false)
    api.SuppressImmersiveCamera(false)
    api.ResetCamera(0)
    applied = false
    if log then log("[HeadTracking] handed Shift's camera presets back") end
end

return ShiftCompat
