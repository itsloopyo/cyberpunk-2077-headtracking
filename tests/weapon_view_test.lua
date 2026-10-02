-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo

local WeaponView = require("modules.weapon_view")
local qmul, qconj, qrot = WeaponView.qmul, WeaponView.qconj, WeaponView.qrot

local function near(a, b, label, tol)
    assert(math.abs(a - b) < (tol or 1e-9),
        (label or "value") .. ": " .. tostring(a) .. " ~= " .. tostring(b))
end

local function near3(a, b, label, tol)
    near(a.x, b.x, label .. " x", tol)
    near(a.y, b.y, label .. " y", tol)
    near(a.z, b.z, label .. " z", tol)
end

local function same_rotation(a, b, label)
    local d = math.abs(a.i * b.i + a.j * b.j + a.k * b.k + a.r * b.r)
    near(d, 1, label, 1e-9)
end

local function axis_angle(x, y, z, degrees)
    local h = math.rad(degrees) / 2
    local s = math.sin(h)
    return { i = x * s, j = y * s, k = z * s, r = math.cos(h) }
end

local function add(a, b) return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z } end
local function sub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end

--- Head yaw about the camera's up axis, then pitch about its right axis.
local function view(yaw, pitch)
    return qmul(axis_angle(0, 0, 1, yaw), axis_angle(1, 0, 0, pitch))
end

do
    near(WeaponView.worldMagnification(1, 0, 0.1), 1, "no override weight leaves the zoom")
    near(WeaponView.worldMagnification(1, 1, 1.6997), 1.6997, "full weight is the override")
    near(WeaponView.worldMagnification(1, 0.5, 1.5), 1.25, "half weight is halfway")

    -- The weapon pass, at the weights and values measured in game.
    near(WeaponView.weaponMagnification(1, 1.9614), 1.9614, "full weight is the override")
    near(WeaponView.weaponMagnification(0.75, 1.5), 1.125, "partial weight scales the value")
    near(WeaponView.weaponMagnification(0.5, 1.5), 1, "and never goes under 1")
    near(WeaponView.weaponMagnification(1, 0.66), 1, "a value under 1 does not shrink the weapon")
    near(WeaponView.weaponMagnification(0.38, 0.1), 1, "the opening frames of an aim draw it unmagnified")
end

-- The turned sight line lands where the world pass draws the aim: its lateral
-- over forward, magnified by the weapon's zoom, is the aim's magnified by the
-- world's.
for _, zooms in ipairs({ { 1.4996, 1.0 }, { 1.6997, 1.9614 }, { 1.0995, 1.0409 }, { 4.0, 1.0 } }) do
    local world, weapon = zooms[1], zooms[2]
    for _, yaw in ipairs({ -30, -12, 0, 12, 30 }) do
        for _, pitch in ipairs({ -15, 0, 15 }) do
            for _, lean in ipairs({ -0.2, 0, 0.2 }) do
                local v = view(yaw, pitch)
                local eye = { x = lean, y = 0.02, z = lean / 4 }
                local weapon_pos = { x = 0.03, y = 0.35, z = -0.08 }
                local turn = WeaponView.turn(v, eye, weapon_pos, weapon / world)
                local sight = { x = -eye.x, y = weapon_pos.y - eye.y, z = -eye.z }
                local right = qrot(v, { x = 1, y = 0, z = 0 })
                local forward = qrot(v, { x = 0, y = 1, z = 0 })
                local up = qrot(v, { x = 0, y = 0, z = 1 })
                local function screen(d, zoom)
                    local f = d.x * forward.x + d.y * forward.y + d.z * forward.z
                    return zoom * (d.x * right.x + d.y * right.y + d.z * right.z) / f,
                           zoom * (d.x * up.x + d.y * up.y + d.z * up.z) / f
                end
                local ax, ay = screen(sight, world)
                local wx, wy = screen(qrot(turn, sight), weapon)
                near(wx, ax, "sight line across the frame")
                near(wy, ay, "sight line up the frame")
            end
        end
    end
end

do
    local turn = WeaponView.turn(view(0, 0), { x = 0, y = 0, z = 0 }, { x = 0, y = 0.3, z = 0 }, 0.6667)
    same_rotation(turn, { i = 0, j = 0, k = 0, r = 1 }, "a centred head turns nothing")
end

-- The rig takes the turn about the rendered eye: the camera does not move or
-- turn, and everything else on the rig goes round the eye by the turn.
do
    local entity_q = axis_angle(0, 0, 1, 30)
    local entity_p = { x = 100, y = 200, z = 1 }
    local bone_q = axis_angle(1, 0, 0, -35)            -- bone in the rig's frame
    local bone_origin = { x = 0.02, y = 0.11, z = 1.7 }
    local function to_root(v) return qrot(bone_q, v) end

    local function world(rig_q, rig_p, camera_q, eye, point)
        local root_q = qmul(entity_q, rig_q)
        local root_p = add(entity_p, qrot(entity_q, rig_p))
        local bq = qmul(root_q, bone_q)
        local bp = add(root_p, qrot(root_q, bone_origin))
        return {
            eye = add(bp, qrot(bq, eye)),
            view = qmul(bq, camera_q),
            point = add(bp, qrot(bq, point)),
            bone_p = bp, bone_q = bq, root_q = root_q,
        }
    end

    local identity = { i = 0, j = 0, k = 0, r = 1 }
    for _, case in ipairs({
        { lean = { x = 0, y = 0, z = 0 }, eye = { x = 0, y = 0, z = 0 } },
        { lean = { x = -0.2, y = 0.08, z = 0.03 }, eye = { x = 0, y = 0, z = 0 } },
        { lean = { x = 0, y = 0, z = 0 }, eye = { x = 0.2, y = 0.05, z = -0.04 } },
        { lean = { x = 0.1, y = 0.02, z = 0 }, eye = { x = -0.12, y = 0.03, z = 0.02 } },
    }) do
        local base = view(14, -6)
        local weapon_pos = { x = 0.04, y = 0.33, z = -0.09 }
        local turn = WeaponView.turn(base, case.eye, weapon_pos, 1.0 / 1.4996)
        local orientation, position, shift = WeaponView.rig(turn, to_root, bone_origin, case.eye, case.lean)

        local before = world(identity, case.lean, base, case.eye, weapon_pos)
        local after = world(orientation, position, qmul(qconj(turn), base), case.eye, weapon_pos)

        near3(after.eye, before.eye, "the eye stays where it was", 1e-9)
        same_rotation(after.view, before.view, "the view stays where it was")

        local world_turn = qmul(qmul(before.bone_q, turn), qconj(before.bone_q))
        local expected = add(before.eye, qrot(world_turn, sub(before.point, before.eye)))
        near3(after.point, expected, "the weapon goes round the eye by the turn", 1e-9)

        local clean_eye = add(entity_p, qrot(entity_q, bone_origin))
        near3(sub(after.bone_p, qrot(after.root_q, shift)), clean_eye,
            "the shift gives the clean eye back from the turned rig", 1e-9)
    end

    do
        local turn = identity
        local lean = { x = -0.2, y = 0.08, z = 0.03 }
        local orientation, position, shift = WeaponView.rig(turn, to_root, bone_origin, { x = 0, y = 0, z = 0 }, lean)
        same_rotation(orientation, identity, "no turn leaves the rig's orientation")
        near3(position, lean, "no turn leaves the lean", 1e-12)
        near3(shift, lean, "and the shift is the lean", 1e-12)
    end
end

print("weapon view: projection and rig checks passed")
