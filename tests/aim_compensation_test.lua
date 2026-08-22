-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo

local function assert_near(actual, expected, label, tolerance)
    tolerance = tolerance or 1e-6
    if math.abs(actual - expected) > tolerance then
        error(string.format("FAIL %s: expected %.12f, got %.12f",
            label, expected, actual), 2)
    end
end

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("FAIL %s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

Vector4 = {
    new = function(x, y, z, w)
        return { x = x, y = y, z = z, w = w }
    end,
}

local AimGeometry = require("modules/aim_geometry")
local right = { x = 1, y = 0, z = 0 }
local forward = { x = 0, y = 1, z = 0 }
local up = { x = 0, y = 0, z = 1 }
local identity = { i = 0, j = 0, k = 0, r = 1 }

print("== aim compensation geometry ==")

local centred = AimGeometry.compensateDirection(
    right, forward, up, forward, identity, 0, 0, 0, 0, false, 7)
assert_near(centred.x, 0, "centred x")
assert_near(centred.y, 1, "centred y")
assert_near(centred.z, 0, "centred z")
assert_eq(centred.w, 7, "centred w")

local translated = AimGeometry.compensateDirection(
    right, forward, up, forward, identity, 0.2, 0.5, 0.4, 10, true, 3)
local translated_len = math.sqrt(0.2 * 0.2 + 10.5 * 10.5 + 0.4 * 0.4)
assert_near(translated.x, -0.2 / translated_len, "translated x")
assert_near(translated.y, 10.5 / translated_len, "translated y")
assert_near(translated.z, -0.4 / translated_len, "translated z")
assert_eq(translated.w, 3, "translated w")

local half = math.sqrt(0.5)
local head_yaw_90 = { i = 0, j = 0, k = half, r = half }
local rendered_right = { x = 0, y = 1, z = 0 }
local rendered_forward = { x = -1, y = 0, z = 0 }
local yaw_peeled = AimGeometry.compensateDirection(
    rendered_right, rendered_forward, up, rendered_forward, head_yaw_90,
    0, 0, 0, 0, false, 0)
assert_near(yaw_peeled.x, 0, "90-degree yaw peel x")
assert_near(yaw_peeled.y, 1, "90-degree yaw peel y")
assert_near(yaw_peeled.z, 0, "90-degree yaw peel z")

local head_roll_90 = { i = 0, j = half, k = 0, r = half }
local rolled_right = { x = 0, y = 0, z = -1 }
local rolled_up = { x = 1, y = 0, z = 0 }
local roll_peeled = AimGeometry.compensateDirection(
    rolled_right, forward, rolled_up, forward, head_roll_90,
    0, 0, 0, 0, false, 0)
assert_near(roll_peeled.x, 0, "90-degree roll peel x")
assert_near(roll_peeled.y, 1, "90-degree roll peel y")
assert_near(roll_peeled.z, 0, "90-degree roll peel z")

local function quat_mul(a, b)
    return {
        i = a.r * b.i + a.i * b.r + a.j * b.k - a.k * b.j,
        j = a.r * b.j - a.i * b.k + a.j * b.r + a.k * b.i,
        k = a.r * b.k + a.i * b.j - a.j * b.i + a.k * b.r,
        r = a.r * b.r - a.i * b.i - a.j * b.j - a.k * b.k,
    }
end

local function axis_quat(x, y, z, degrees)
    local half_angle = math.rad(degrees) * 0.5
    local s = math.sin(half_angle)
    return { i = x * s, j = y * s, k = z * s, r = math.cos(half_angle) }
end

local function rotate(q, x, y, z)
    local cx = q.j * z - q.k * y
    local cy = q.k * x - q.i * z
    local cz = q.i * y - q.j * x
    return {
        x = x + 2 * (q.r * cx + q.j * cz - q.k * cy),
        y = y + 2 * (q.r * cy + q.k * cx - q.i * cz),
        z = z + 2 * (q.r * cz + q.i * cy - q.j * cx),
    }
end

local clean_quat = quat_mul(axis_quat(0, 0, 1, 37), axis_quat(1, 0, 0, -23))
local head_quat = quat_mul(
    axis_quat(0, 0, 1, -31),
    quat_mul(axis_quat(1, 0, 0, 19), axis_quat(0, 1, 0, 12)))
local rendered_quat = quat_mul(clean_quat, head_quat)
local combined_right = rotate(rendered_quat, 1, 0, 0)
local combined_forward = rotate(rendered_quat, 0, 1, 0)
local combined_up = rotate(rendered_quat, 0, 0, 1)

local px, py, pz, distance = 0.27, -0.18, 0.11, 7.5
local tx, ty, tz = -px, distance + py, -pz
local target_len = math.sqrt(tx * tx + ty * ty + tz * tz)
local target_x, target_y, target_z = tx / target_len, ty / target_len, tz / target_len
local parallax_quat = {
    i = target_z,
    j = 0,
    k = -target_x,
    r = 1 + target_y,
}
local parallax_len = math.sqrt(
    parallax_quat.i * parallax_quat.i + parallax_quat.k * parallax_quat.k
        + parallax_quat.r * parallax_quat.r)
parallax_quat.i = parallax_quat.i / parallax_len
parallax_quat.k = parallax_quat.k / parallax_len
parallax_quat.r = parallax_quat.r / parallax_len

local native_output_quat = quat_mul(clean_quat, parallax_quat)
local native_direction = rotate(native_output_quat, 0, 1, 0)
local lua_direction = AimGeometry.compensateDirection(
    combined_right, combined_forward, combined_up, combined_forward, head_quat,
    px, py, pz, distance, true, 0)
assert_near(lua_direction.x, native_direction.x, "combined pose matches native x")
assert_near(lua_direction.y, native_direction.y, "combined pose matches native y")
assert_near(lua_direction.z, native_direction.z, "combined pose matches native z")

local sway_local = { x = 0.04, y = 0.99795, z = -0.05 }
local sway_length = math.sqrt(
    sway_local.x * sway_local.x + sway_local.y * sway_local.y + sway_local.z * sway_local.z)
sway_local.x = sway_local.x / sway_length
sway_local.y = sway_local.y / sway_length
sway_local.z = sway_local.z / sway_length
local swayed_forward = rotate(
    rendered_quat, sway_local.x, sway_local.y, sway_local.z)
local swayed_tx = sway_local.x * distance - px
local swayed_ty = sway_local.y * distance + py
local swayed_tz = sway_local.z * distance - pz
local expected_sway_direction = rotate(clean_quat, swayed_tx, swayed_ty, swayed_tz)
local expected_sway_length = math.sqrt(
    expected_sway_direction.x * expected_sway_direction.x
        + expected_sway_direction.y * expected_sway_direction.y
        + expected_sway_direction.z * expected_sway_direction.z)
local swayed_direction = AimGeometry.compensateDirection(
    combined_right, combined_forward, combined_up, swayed_forward, head_quat,
    px, py, pz, distance, true, 0)
assert_near(swayed_direction.x,
    expected_sway_direction.x / expected_sway_length, "sway preserved x")
assert_near(swayed_direction.y,
    expected_sway_direction.y / expected_sway_length, "sway preserved y")
assert_near(swayed_direction.z,
    expected_sway_direction.z / expected_sway_length, "sway preserved z")

local aim_source = assert(io.open("modules/aim.lua", "rb")):read("*a")
for _, method in ipairs({ "GetCrosshairData", "GetDefaultCrosshairData" }) do
    local callback = aim_source:match(
        'Override%(%' .. '"TargetingSystem"' .. '%, %"' .. method .. '%",%s*(function%b())')
    if not callback then
        error("FAIL could not find " .. method .. " override callback")
    end
    if not callback:find(
            "this, instigator, crosshairPosition, crosshairForward, wrappedMethod",
            1, true) then
        error("FAIL " .. method .. " must accept both CET OUT parameters before wrappedMethod")
    end
end

print("== Aim compensation geometry OK ==")
