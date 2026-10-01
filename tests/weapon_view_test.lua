-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo

local WeaponView = require("modules.weapon_view")
local function camera()
    return {
        zoom = 1, zoomOverrideWeight = 1, zoomOverrideValue = 1.6997,
        zoomWeaponOverrideWeight = 1, zoomWeaponOverrideValue = 1.9614,
    }
end

local function near(a, b)
    assert(math.abs(a - b) < 1e-6, tostring(a) .. " ~= " .. tostring(b))
end

local function zoom(c, weight, value)
    return c.zoom * (1 - weight) + value * weight
end

for _, state in ipairs({
    { 0, 1, 0, 0.1 },
    { 0.5, 1.7, 0.25, 0.1 },
    { 1, 1.6997, 1, 1.9614 },
    { 1, 4, 0, 0.1 },
}) do
    local c, view = camera(), WeaponView.new()
    c.zoomOverrideWeight, c.zoomOverrideValue = state[1], state[2]
    c.zoomWeaponOverrideWeight, c.zoomWeaponOverrideValue = state[3], state[4]
    view:apply(c)
    local world = zoom(c, c.zoomOverrideWeight, c.zoomOverrideValue)
    local weapon = zoom(c, c.zoomWeaponOverrideWeight, c.zoomWeaponOverrideValue)
    for _, yaw in ipairs({ -45, -12, 0, 12, 45 }) do
        for _, pitch in ipairs({ -20, 0, 20 }) do
            for _, lean in ipairs({ -0.2, 0, 0.2 }) do
                local x = math.tan(math.rad(yaw)) + lean / 0.3
                local y = math.tan(math.rad(pitch))
                near(weapon * x, world * x)
                near(weapon * y, world * y)
            end
        end
    end
    view:apply(c)
    view:release(c)
    near(c.zoomWeaponOverrideWeight, state[3])
    near(c.zoomWeaponOverrideValue, state[4])
    near(c.zoomOverrideWeight, state[1])
    near(c.zoomOverrideValue, state[2])
end

do
    local c, view = camera(), WeaponView.new()
    view:apply(c)
    c.zoomOverrideValue = 2
    view:apply(c)
    near(c.zoomWeaponOverrideValue, 2)
    view:release(c)
    near(c.zoomWeaponOverrideValue, 1.9614)
end

do
    local c, view = camera(), WeaponView.new()
    view:apply(c)
    c.zoomWeaponOverrideWeight, c.zoomWeaponOverrideValue = 0.4, 1.2
    view:apply(c)
    view:release(c)
    near(c.zoomWeaponOverrideWeight, 0.4)
    near(c.zoomWeaponOverrideValue, 1.2)
end

do
    local c, view = camera(), WeaponView.new()
    view:apply(c)
    c.zoomWeaponOverrideWeight, c.zoomWeaponOverrideValue = 0, 0.1
    view:release(c)
    near(c.zoomWeaponOverrideWeight, 0)
    near(c.zoomWeaponOverrideValue, 0.1)
end

for _, operation in ipairs({ "apply", "release" }) do
    local c, view = camera(), WeaponView.new()
    view:apply(c)
    view[operation](view, nil)
    local next_camera = camera()
    next_camera.zoomWeaponOverrideValue = 2.5
    view:apply(next_camera)
    for _, value in pairs(view) do
        assert(type(value) == "number", "no engine handles retained")
    end
    view:release(next_camera)
    near(next_camera.zoomWeaponOverrideValue, 2.5)
end

print("weapon view: projection and lifecycle checks passed")
