-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("FAIL %s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

local function assert_near(actual, expected, label, tolerance)
    tolerance = tolerance or 1e-6
    if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
        error(string.format("FAIL %s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

local BuiltinCrosshair = require("modules/builtin_crosshair")

print("== reticle projection ==")

local saved_clock = os.clock
local now = 1
os.clock = function() return now end

local raycasts = 0
local next_distance = 2
local next_normal = { x = 0, y = -1, z = 0 }
local sampled_crosshair_calls = 0
local default_crosshair_calls = 0
local targeting = {
    GetCrosshairData = function()
        sampled_crosshair_calls = sampled_crosshair_calls + 1
        return { x = 90, y = 80, z = 70, w = 1 },
               { x = 1, y = 0, z = 0, w = 0 }
    end,
    GetDefaultCrosshairData = function()
        default_crosshair_calls = default_crosshair_calls + 1
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
        local dx = to.x - from.x
        local dy = to.y - from.y
        local dz = to.z - from.z
        local length = math.sqrt(dx * dx + dy * dy + dz * dz)
        assert_near(length, 1000, "ray length", 1e-3)
        if next_distance == nil then return false, {} end
        return true, {
            position = {
                x = from.x + dx / length * next_distance,
                y = from.y + dy / length * next_distance,
                z = from.z + dz / length * next_distance,
            },
            normal = next_normal,
        }
    end,
}
spatial.SyncRaycastByCollisionPreset = function(_, from, to, preset, a, b)
    assert_eq(preset, "World Static", "raycast collision preset")
    return spatial.SyncRaycastByCollisionGroup(
        spatial, from, to, "Static", false, false)
end
local project_calls = 0
local camera_forward = { x = 0, y = 1, z = 0, w = 0 }
local normalized_sway = { X = 0.1, Y = -0.2 }
local camera_system = {
    GetActiveCameraForward = function()
        return camera_forward
    end,
    ProjectPoint = function(_, point)
        project_calls = project_calls + 1
        assert_near(point.x, 1, "projected point x")
        assert_near(point.y, 12, "projected point y")
        assert_near(point.z, 3, "projected point z")
        return { x = 0.25, y = -0.5, z = 0.9, w = 1 }
    end,
    UnprojectPoint = function(_, point)
        assert_near(point.x, 0.35, "unprojected sway x")
        assert_near(point.y, -0.3, "unprojected sway y")
        return { x = 1, y = 3, z = 3, w = 1 }
    end,
}

Game = {
    GetPlayer = function() return {} end,
    GetTargetingSystem = function() return targeting end,
    GetSpatialQueriesSystem = function() return spatial end,
    GetCameraSystem = function() return camera_system end,
    GetUISystem = function()
        return {
            GetCurrentWindowSize = function() return { X = 1000, Y = 800 } end,
            GetInverseUIScale = function() return 0.8 end,
        }
    end,
    GetBlackboardSystem = function()
        return {
            Get = function()
                return {
                    GetVector2 = function()
                        return normalized_sway
                    end,
                }
            end,
        }
    end,
}
GetAllBlackboardDefs = function()
    return { UIGameData = { NormalizedWeaponSway = "NormalizedWeaponSway" } }
end
Vector4 = {
    new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
}
Vector2 = {
    new = function(x, y) return { x = x, y = y } end,
}

local driver = setmetatable({
    _aim_distance = nil,
    _aim_distance_sample_t = nil,
    _aim_distance_error_logged = false,
}, BuiltinCrosshair)

local distance = driver:_getAimDistance({}, true)
assert_near(distance, 2, "first raycast distance")
assert_eq(raycasts, 1, "first sample raycast count")
assert_eq(default_crosshair_calls, 1, "distance uses default crosshair axis")
assert_eq(sampled_crosshair_calls, 0, "distance does not consume spread sample")

now = 1.01
next_distance = 10
distance = driver:_getAimDistance({}, true)
if distance <= 2 or distance >= 10 then
    error("FAIL changed hit distance was not smoothed", 2)
end
assert_eq(raycasts, 2, "second-frame sample raycast count")

now = 1.04
distance = driver:_getAimDistance({}, true)
if distance <= 2 or distance >= 10 then
    error("FAIL changed hit distance was not smoothed", 2)
end
assert_eq(raycasts, 3, "third-frame sample raycast count")

now = 1.06
next_normal = nil
distance = driver:_getAimDistance({}, true)
assert_eq(raycasts, 4, "a surface with no normal still samples once")

now = 1.08
next_distance = nil
distance = driver:_getAimDistance({}, true)
assert_eq(distance, nil, "miss projects at infinity immediately")
assert_eq(driver._aim_distance, nil, "miss clears smoothed hit distance")

now = 1.12
driver:_getAimDistance({}, false)
assert_eq(raycasts, 8, "a miss falls back to the world-static preset once")

local screen_dx, screen_dy, screen_valid = driver:_computeOffset(1000, 800)
assert_eq(screen_valid, true, "engine projection is valid")
assert_near(screen_dx, 175, "engine projection includes horizontal weapon sway")
assert_near(screen_dy, 120, "engine projection includes vertical weapon sway")
assert_eq(project_calls, 7, "engine projector called for aim samples and reticle")
assert_eq(default_crosshair_calls, 7, "projection uses default crosshair axis")
assert_eq(sampled_crosshair_calls, 0, "projection does not consume spread sample")

targeting.GetDefaultCrosshairData = function()
    default_crosshair_calls = default_crosshair_calls + 1
    return { x = 1, y = 2, z = 3, w = 1 },
           { x = 0, y = -1, z = 0, w = 0 }
end
_, _, screen_valid = driver:_computeOffset(1000, 800)
assert_eq(screen_valid, false, "target behind camera is hidden")
assert_eq(project_calls, 7, "behind-camera target is not projected")

GetDisplayResolution = function() return 1000, 800 end
local marker_root_margin = { left = 0, top = 0 }
local marker_margin = { left = 0, top = 0 }
local marker_active_widget
local marker_root = {
    SetMargin = function(_, value) marker_root_margin = value end,
    GetMargin = function() return marker_root_margin end,
    GetNumChildren = function() return 1 end,
    GetWidgetByIndex = function(_, index)
        assert_eq(index, 0, "hit marker child index")
        return marker_active_widget
    end,
}
marker_active_widget = {
    SetMargin = function(_, value) marker_margin = value end,
    GetMargin = function() return marker_margin end,
}
inkMargin = {
    new = function(value) return value end,
}
driver.hit_markers = {
    {
        ctrl = {
            GetRootWidget = function() return marker_root end,
        },
        class = "TargetHitIndicatorGameController",
        children_logged = false,
    },
}
driver._hit_marker_tracking_allowed = true
driver._shove_hitmarker = true
driver:_writeHitMarkersAtAim(125, 200, true)
assert_near(marker_margin.left, 100, "hit marker UI-scaled x")
assert_near(marker_margin.top, 160, "hit marker UI-scaled y")
assert_near(marker_root_margin.left, 0, "hit marker root reset x")
assert_near(marker_root_margin.top, 0, "hit marker root reset y")

os.clock = saved_clock

print("== reticle projection OK ==")
