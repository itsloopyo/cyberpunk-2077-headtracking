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
-- The settings defaults are read off a live Settings instance. The two ramp
-- ends in camera.lua and the interpolator constants in poseinterpolator.lua are
-- module-locals on purpose - nothing outside those files may set them - so they
-- are read from the source declaration rather than widened into module exports
-- for a test's benefit.
--
-- Not pinned, and why:
--   settings.position_limit_y_down is 0.05 against core's 0.20. Every mod in
--   the fleet tightens the downward budget; the camera sits at the eyes and the
--   extra travel clips into the player body. Per-game, not a restated default.

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

package.path = "./?.lua;./modules/?.lua;" .. package.path
local Settings = require("modules.settings")
if not Settings then Settings = require("settings") end

local defaults = Settings.new().defaults

assert_eq(defaults.local_smoothing, core("local_smoothing_default"), "local_smoothing")
assert_eq(defaults.remote_smoothing, core("remote_smoothing_default"), "remote_smoothing")
assert_eq(defaults.position_limit_x, core("limit_x"), "position_limit_x")
assert_eq(defaults.position_limit_y_up, core("limit_y"), "position_limit_y_up")
assert_eq(defaults.position_limit_z_fwd, core("limit_z"), "position_limit_z_fwd")
assert_eq(defaults.position_limit_z_back, core("limit_z_back"), "position_limit_z_back")

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
