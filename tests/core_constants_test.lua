-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Pins this port's copies of the shared tuning constants to
-- cameraunlock-core/data/pipeline-conformance.json.
--
-- A Lua port cannot reference the C++ or C# symbol, so nothing carries a core
-- change into it. The conformance vectors do not cover it either: they pass
-- smoothing and the limits in as step config, so they exercise the maths and
-- never the defaults. Without this file a moved core constant leaves the mod
-- quietly on the old number.
--
local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format(
            "FAIL %s: cameraunlock-core says %s, this port says %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

local function read_file(path)
    local f = assert(io.open(path, "rb"), "cannot open " .. path)
    local text = f:read("a")
    f:close()
    return text
end

local CONFORMANCE = read_file("cameraunlock-core/data/pipeline-conformance.json")

--- The numeric "value" of one entry in the constants block.
local function core(name)
    local after = CONFORMANCE:match('"' .. name .. '"%s*:%s*{(.-)}')
    if not after then
        error(name .. " is not in the constants block of pipeline-conformance.json", 2)
    end
    local value = after:match('"value"%s*:%s*(-?[%d%.eE+-]+)')
    if not value then error(name .. " has no numeric value", 2) end
    return tonumber(value)
end

--- The right-hand side of `local NAME = <number>` in a module's source.
local function module_local(path, name)
    local text = read_file(path)
    local value = text:match("\nlocal%s+" .. name .. "%s*=%s*([^\r\n%-]+)")
    if not value then error(name .. " is not declared in " .. path, 2) end
    local chunk = assert(load("return " .. value, name))
    return chunk()
end

assert_eq(module_local("modules/camera.lua", "FRAME_INTERPOLATION_SPEED"),
    core("frame_interpolation_speed"), "camera.FRAME_INTERPOLATION_SPEED")
assert_eq(module_local("modules/camera.lua", "MAX_SMOOTHING_SPEED"),
    core("max_smoothing_speed"), "camera.MAX_SMOOTHING_SPEED")

local interp = "modules/poseinterpolator.lua"
assert_eq(module_local(interp, "INTERVAL_BLEND"), core("interval_blend"), "INTERVAL_BLEND")
assert_eq(module_local(interp, "DEFAULT_SAMPLE_INTERVAL"),
    core("default_sample_interval"), "DEFAULT_SAMPLE_INTERVAL")
assert_eq(module_local(interp, "MIN_SAMPLE_INTERVAL"),
    core("min_sample_interval"), "MIN_SAMPLE_INTERVAL")
assert_eq(module_local(interp, "MAX_SAMPLE_INTERVAL"),
    core("max_sample_interval"), "MAX_SAMPLE_INTERVAL")
assert_eq(module_local(interp, "EXTRAPOLATION_HOLD_SECONDS"),
    core("extrapolation_hold_seconds"), "EXTRAPOLATION_HOLD_SECONDS")
assert_eq(module_local(interp, "EXTRAPOLATION_DECAY_SECONDS"),
    core("extrapolation_decay_seconds"), "EXTRAPOLATION_DECAY_SECONDS")

-- The ADS transition. Core spells the two durations in milliseconds because its
-- callers hand it a millisecond clock; every clock in this port is os.clock(),
-- which is seconds, so the module holds seconds and the conversion happens here
-- rather than on every frame.
local fade = "modules/ads_fade.lua"
assert_eq(module_local(fade, "LOWER_S") * 1000, core("ads_fade_lower_ms"), "ads_fade.LOWER_S")
assert_eq(module_local(fade, "RAISE_S") * 1000, core("ads_fade_raise_ms"), "ads_fade.RAISE_S")

print("core_constants_test: all constants match cameraunlock-core")
