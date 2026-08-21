-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("FAIL %s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

local function assert_true(v, label)
    if not v then error("FAIL " .. label .. ": expected truthy, got " .. tostring(v), 2) end
end

local function assert_near(actual, expected, label, tolerance)
    tolerance = tolerance or 1e-6
    if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
        error(string.format("FAIL %s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

local BuiltinCrosshair = require("modules/builtin_crosshair")
local project = BuiltinCrosshair.projectAimOffset

print("== reticle projection ==")

local dx, dy, valid = project(0, 0, 0, 0, 0, 0, 10, 90, 90, 1000, 1000)
assert_eq(valid, true, "centred projection is valid")
assert_near(dx, 0, "centred projection x")
assert_near(dy, 0, "centred projection y")

local near_dx = project(0, 0, 0, 0.2, 0, 0, 2, 90, 90, 1000, 1000)
local far_dx = project(0, 0, 0, 0.2, 0, 0, 10, 90, 90, 1000, 1000)
assert_near(near_dx, -50, "positive camera X moves target left at 2 m")
assert_near(far_dx, -10, "positive camera X moves target left at 10 m")
local tracker_right_dx = project(0, 0, 0, -0.2, 0, 0, 2, 90, 90, 1000, 1000)
assert_near(tracker_right_dx, 50, "negative camera X moves target right")

dx, dy = project(0, 0, 0, 0, 0, 0.2, 2, 90, 90, 1000, 1000)
assert_near(dx, 0, "vertical translation leaves x centred")
assert_near(dy, 50, "camera-up offset moves target down")

local forward_dx = project(0, 0, 0, 0.2, -0.5, 0, 2, 90, 90, 1000, 1000)
local backward_dx = project(0, 0, 0, 0.2, 0.5, 0, 2, 90, 90, 1000, 1000)
assert_near(forward_dx, -200 / 3, "camera-forward offset reduces target depth")
assert_near(backward_dx, -40, "camera-back offset increases target depth")

dx, dy = project(0, 0, 0, 5, 5, 5, nil, 90, 90, 1000, 1000)
assert_near(dx, 0, "miss projects lateral position at infinity")
assert_near(dy, 0, "miss projects vertical position at infinity")

local near_rot_dx = project(15, 0, 0, 0, 0, 0, 2, 90, 90, 1000, 1000)
local far_rot_dx = project(15, 0, 0, 0, 0, 0, 100, 90, 90, 1000, 1000)
assert_near(near_rot_dx, far_rot_dx, "rotation is independent of target depth")

-- Cyberpunk's rendered camera yaw is negative for a physical right turn. The
-- aim point must move left on screen. Positive pitch is a physical upward turn
-- and must move the aim point down in screen coordinates.
assert_true(project(-15, 0, 0, 0, 0, 0, 10, 90, 90, 1000, 1000) < 0,
    "right head turn moves the target left on screen")
assert_true(project(15, 0, 0, 0, 0, 0, 10, 90, 90, 1000, 1000) > 0,
    "left head turn moves the target right on screen")
local _, pitch_dy = project(0, 15, 0, 0, 0, 0, 10, 90, 90, 1000, 1000)
assert_true(pitch_dy > 0, "head tilted up moves the target down on screen")

local saved_clock = os.clock
local now = 1
os.clock = function() return now end

local raycasts = 0
local next_distance = 2
local targeting = {
    GetCrosshairData = function()
        return { x = 1, y = 2, z = 3, w = 1 },
               { x = 0, y = 1, z = 0, w = 0 }
    end,
}
local spatial = {
    SyncRaycastByCollisionGroup = function(_, from, to, group, a, b)
        raycasts = raycasts + 1
        assert_eq(group, "Static", "raycast collision group")
        assert_eq(a, false, "raycast flag a")
        assert_eq(b, false, "raycast flag b")
        assert_near(to.x, from.x, "ray end x")
        assert_near(to.y, from.y + 1000, "ray end y")
        assert_near(to.z, from.z, "ray end z")
        if next_distance == nil then return false, {} end
        return true, {
            position = { x = from.x, y = from.y + next_distance, z = from.z },
        }
    end,
}

Game = {
    GetTargetingSystem = function() return targeting end,
    GetSpatialQueriesSystem = function() return spatial end,
}
Vector4 = {
    new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
}

local driver = setmetatable({
    _aim_distance = nil,
    _aim_distance_sample_t = nil,
    _aim_distance_next_t = 0,
    _aim_distance_error_logged = false,
}, BuiltinCrosshair)

local distance = driver:_getAimDistance({}, true)
assert_near(distance, 2, "first raycast distance")
assert_eq(raycasts, 1, "first sample raycast count")

now = 1.01
next_distance = 10
distance = driver:_getAimDistance({}, true)
assert_near(distance, 2, "distance cached inside sample interval")
assert_eq(raycasts, 1, "cached sample raycast count")

now = 1.04
distance = driver:_getAimDistance({}, true)
if distance <= 2 or distance >= 10 then
    error("FAIL changed hit distance was not smoothed", 2)
end
assert_eq(raycasts, 2, "second sample raycast count")

now = 1.08
next_distance = nil
distance = driver:_getAimDistance({}, true)
assert_eq(distance, nil, "miss projects at infinity immediately")
assert_eq(driver._aim_distance, nil, "miss clears smoothed hit distance")

now = 1.12
driver:_getAimDistance({}, false)
assert_eq(raycasts, 3, "no raycast without positional tracking")

os.clock = saved_clock

print("== reticle projection OK ==")
