-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Equivalence test for aim.lua's compensateForward() extraction.
--
-- modules/aim.lua registers CET Overrides for GetCrosshairData,
-- GetBestComponentOnTargetObject, and GetDefaultCrosshairData. Each one used
-- to spell out the same decision inline:
--
--     if not aim_state.enabled or not fwd then return <original> end
--     local yaw, pitch = aim_state.smooth_yaw, aim_state.smooth_pitch
--     if math_abs(yaw) < 0.1 and math_abs(pitch) < 0.1 then return <original> end
--     return rotateVectorByAngles(fwd, -yaw, -pitch)
--
-- That is now a single compensateForward(fwd). This is the aim-decoupling
-- hot path - it decides where every bullet goes - so the extraction is pinned
-- here against a verbatim copy of the original inline form.
--
-- The two implementations below mirror modules/aim.lua. If that file's
-- compensateForward changes, update `extracted` and re-run.

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("FAIL %s:\n  expected: %s\n  actual:   %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

local math_abs, math_rad, math_cos, math_sin =
      math.abs, math.rad, math.cos, math.sin

-- Stand-in for CET's Vector4 userdata.
_G.Vector4 = {
    new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
}

local aim_state = { enabled = true, smooth_yaw = 0, smooth_pitch = 0 }

-- Copied verbatim from modules/aim.lua.
local function rotateVectorByAngles(vec, yaw_deg, pitch_deg)
    local yaw = math_rad(yaw_deg)
    local pitch = math_rad(pitch_deg)

    local cy = math_cos(yaw)
    local sy = math_sin(yaw)
    local cp = math_cos(pitch)
    local sp = math_sin(pitch)

    local x = vec.x
    local y = vec.y
    local z = vec.z

    local x1 = x * cy - y * sy
    local y1 = x * sy + y * cy
    local z1 = z

    local x2 = x1
    local y2 = y1 * cp - z1 * sp
    local z2 = y1 * sp + z1 * cp

    return Vector4.new(x2, y2, z2, vec.w)
end

-- ---------------------------------------------------------------------------
-- ORIGINAL: the inline form, as it appeared in each of the five Overrides.
-- ---------------------------------------------------------------------------
local function original(fwd)
    if not aim_state.enabled or not fwd then
        return fwd
    end
    local yaw = aim_state.smooth_yaw
    local pitch = aim_state.smooth_pitch
    if math_abs(yaw) < 0.1 and math_abs(pitch) < 0.1 then
        return fwd
    end
    return rotateVectorByAngles(fwd, -yaw, -pitch)
end

-- ---------------------------------------------------------------------------
-- EXTRACTED: copied from modules/aim.lua.
-- ---------------------------------------------------------------------------
local AIM_COMPENSATION_MIN_DEGREES = 0.1

local function extracted(fwd)
    if not aim_state.enabled or not fwd then
        return fwd
    end

    local yaw = aim_state.smooth_yaw
    local pitch = aim_state.smooth_pitch
    if math_abs(yaw) < AIM_COMPENSATION_MIN_DEGREES
       and math_abs(pitch) < AIM_COMPENSATION_MIN_DEGREES then
        return fwd
    end

    return rotateVectorByAngles(fwd, -yaw, -pitch)
end

print("== aim compensation equivalence ==")

-- Deadzone boundary values matter most: 0.1 is the threshold, and the guard
-- is an AND, so one axis alone crossing it must still compensate.
local ANGLES = {
    0, 0.05, 0.0999, 0.1, 0.1001, 1, -1, 15, -15, 44.9, 90, -90, 179.9, 360,
}
local VECTORS = {
    { x = 0, y = 1, z = 0, w = 0 },
    { x = 1, y = 0, z = 0, w = 1 },
    { x = 0, y = 0, z = 1, w = 0 },
    { x = 0.3, y = -0.6, z = 0.74, w = 1 },
    { x = 0, y = 0, z = 0, w = 0 },
}

local checks = 0
for _, enabled in ipairs({ true, false }) do
    for _, yaw in ipairs(ANGLES) do
        for _, pitch in ipairs(ANGLES) do
            for _, vec in ipairs(VECTORS) do
                aim_state.enabled = enabled
                aim_state.smooth_yaw = yaw
                aim_state.smooth_pitch = pitch

                local label = string.format(
                    "enabled=%s yaw=%s pitch=%s vec=(%s,%s,%s,%s)",
                    tostring(enabled), tostring(yaw), tostring(pitch),
                    tostring(vec.x), tostring(vec.y), tostring(vec.z), tostring(vec.w))

                local a = original(vec)
                local b = extracted(vec)

                -- The untouched path must return the SAME OBJECT, not a copy:
                -- callers hand this straight back to the engine.
                if a == vec then
                    assert_eq(b, vec, label .. " -> returns input unchanged (identity)")
                else
                    assert_eq(type(b), "table", label .. " -> compensated is a table")
                    assert_eq(b.x, a.x, label .. " -> x")
                    assert_eq(b.y, a.y, label .. " -> y")
                    assert_eq(b.z, a.z, label .. " -> z")
                    assert_eq(b.w, a.w, label .. " -> w (must be preserved)")
                end
                checks = checks + 1
            end
        end
    end
end

-- nil forward: both must hand nil straight back rather than throwing.
for _, enabled in ipairs({ true, false }) do
    aim_state.enabled = enabled
    aim_state.smooth_yaw, aim_state.smooth_pitch = 30, 30
    assert_eq(extracted(nil), original(nil), "nil forward (enabled=" .. tostring(enabled) .. ")")
    assert_eq(extracted(nil), nil, "nil forward returns nil")
    checks = checks + 1
end

print(string.format("== Aim compensation equivalence OK: %d cases ==", checks))

local aim_source = assert(io.open("modules/aim.lua", "rb")):read("*a")
for _, method in ipairs({ "GetCrosshairData", "GetDefaultCrosshairData" }) do
    local callback = aim_source:match(
        'Override%(%"TargetingSystem%", %"' .. method .. '%",%s*(function%b())')
    if not callback then
        error("FAIL could not find " .. method .. " override callback")
    end
    if not callback:find(
            "this, instigator, crosshairPosition, crosshairForward, wrappedMethod",
            1, true) then
        error("FAIL " .. method .. " must accept both CET OUT parameters before wrappedMethod")
    end
end

print("== Aim override OUT parameter signatures OK ==")
