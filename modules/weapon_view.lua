-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Weapon View Module
--
-- The weapon and the arms are drawn in their own pass, magnified by their own
-- zoom: aiming zooms the world by zoomOverrideValue and the weapon by
-- zoomWeaponOverrideValue (1.50 and 1.00 on the Satara, 1.70 and 1.96 on the
-- Grad's long scope). Without head tracking that costs nothing, because the
-- weapon sits on the view axis. With the head turned the weapon's axis is off to
-- one side, and the weapon pass throws it a different distance across the frame
-- than the world pass throws the aim point, by the ratio of the two zooms.
--
-- The fix turns the rig the weapon hangs off about the rendered eye, so the
-- sight line comes out where the world pass draws the aim: in the rendered
-- camera's frame the lateral components of the direction to the sight line are
-- divided by the ratio and the forward one kept, and the rig takes the shortest
-- arc between the two. The rig carries the arms, the weapon and the camera
-- together, so the hands stay on the weapon, and the camera takes the opposite
-- turn so the view does not move. The round is untouched; it leaves along the
-- clean aim either way.
--
-- The zooms themselves are left alone. The engine rewrites the weapon's on
-- every frame of the aim transition, so a value written over it lands late and
-- in one step, and the weapon's size is the game's to choose.
--
-- Pure math on plain {x, y, z} and {i, j, k, r} tables, so it runs under the
-- test harness. Cyberpunk's camera frame is +X right, +Y forward, +Z up.

local WeaponView = {}

local function dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function normalize(v)
    local l = math.sqrt(dot(v, v))
    return { x = v.x / l, y = v.y / l, z = v.z / l }
end

local function qmul(a, b)
    return {
        i = a.r * b.i + a.i * b.r + a.j * b.k - a.k * b.j,
        j = a.r * b.j - a.i * b.k + a.j * b.r + a.k * b.i,
        k = a.r * b.k + a.i * b.j - a.j * b.i + a.k * b.r,
        r = a.r * b.r - a.i * b.i - a.j * b.j - a.k * b.k,
    }
end

local function qconj(q)
    return { i = -q.i, j = -q.j, k = -q.k, r = q.r }
end

local function qrot(q, v)
    local p = qmul(qmul(q, { i = v.x, j = v.y, k = v.z, r = 0 }), qconj(q))
    return { x = p.i, y = p.j, z = p.k }
end

-- Shortest arc taking unit a onto unit b. The two are never near opposite: b is
-- a with its lateral part rescaled.
local function arc(a, b)
    local q = {
        i = a.y * b.z - a.z * b.y,
        j = a.z * b.x - a.x * b.z,
        k = a.x * b.y - a.y * b.x,
        r = 1 + dot(a, b),
    }
    local l = math.sqrt(q.i * q.i + q.j * q.j + q.k * q.k + q.r * q.r)
    return { i = q.i / l, j = q.j / l, k = q.k / l, r = q.r / l }
end

WeaponView.qmul = qmul
WeaponView.qconj = qconj
WeaponView.qrot = qrot

--- The magnification the world pass is drawn at: the camera's zoom blended
--- toward the override value by the override weight. Measured in game at 1.250
--- for half weight on 1.5 and 1.500 for full.
function WeaponView.worldMagnification(zoom, weight, value)
    return zoom * (1 - weight) + value * weight
end

--- The magnification the weapon pass is drawn at. Not the same blend: the
--- weapon's is weight times value and never under 1. Measured in game on an
--- override value of 1.5 at 1.004, 1.127, 1.351, 1.490 and 1.508 for weights of
--- 0.5, 0.75, 0.9, 0.99 and 1, and at 1.000 for a full-weight value of 0.66.
--- The engine holds the value at 0.1 while the weight ramps up at the start of
--- an aim, which this reads as no magnification, as the game draws it.
function WeaponView.weaponMagnification(weight, value)
    return math.max(1, weight * value)
end

--- The turn to give the rig, in the camera bone's frame, about the rendered eye.
---
--- The sight line runs from the bone's origin along the bone's forward axis. The
--- point on it at the weapon's depth is where the weapon has to appear, so the
--- turn is taken on the direction from the rendered eye to that point. With the
--- eye on the sight line (sights locked) that is the aim itself; with the eye
--- leaned off it (true free look) it is the parallax the weapon pass would
--- otherwise rescale.
--- @param view table The camera's orientation in the bone's frame, quaternion
--- @param eye table The camera's position in the bone's frame
--- @param weapon_pos table The weapon's origin in the bone's frame
--- @param ratio number Weapon magnification over world magnification
--- @return table quaternion
function WeaponView.turn(view, eye, weapon_pos, ratio)
    local v = { x = -eye.x, y = weapon_pos.y - eye.y, z = -eye.z }
    local right = qrot(view, { x = 1, y = 0, z = 0 })
    local forward = qrot(view, { x = 0, y = 1, z = 0 })
    local up = qrot(view, { x = 0, y = 0, z = 1 })
    local cx, cy, cz = dot(v, right) / ratio, dot(v, forward), dot(v, up) / ratio
    local w = {
        x = right.x * cx + forward.x * cy + up.x * cz,
        y = right.y * cx + forward.y * cy + up.y * cz,
        z = right.z * cx + forward.z * cy + up.z * cz,
    }
    return arc(normalize(v), normalize(w))
end

--- What to write to the rig so it takes `turn` about the rendered eye on top of
--- the lean it already carries.
---
--- The rig's local transform is in its parent's frame, the turn and the eye are
--- in the camera bone's. `to_root` carries a bone-frame vector into the rig's
--- frame; it is read off the two components' world matrices, and it does not
--- change when the rig is turned, because the bone turns with it.
--- @param turn table Quaternion, bone frame
--- @param to_root function Bone-frame vector to the rig's frame
--- @param bone_origin table The bone's origin in the rig's frame
--- @param eye table The camera's position in the bone's frame
--- @param lean table The lean the rig carries, in the rig's parent frame
--- @return table orientation, table position, table shift
---   `shift` is how far the bone's origin now sits from the clean, unleaned eye,
---   in the turned rig's own axes, for whoever needs that eye back next frame.
function WeaponView.rig(turn, to_root, bone_origin, eye, lean)
    local axis = to_root({ x = turn.i, y = turn.j, z = turn.k })
    local orientation = { i = axis.x, j = axis.y, k = axis.z, r = turn.r }
    local e = to_root(eye)
    local arm = { x = bone_origin.x + e.x, y = bone_origin.y + e.y, z = bone_origin.z + e.z }
    local turned = qrot(orientation, arm)
    local position = {
        x = lean.x + arm.x - turned.x,
        y = lean.y + arm.y - turned.y,
        z = lean.z + arm.z - turned.z,
    }
    local back = qrot(qconj(orientation), { x = lean.x + e.x, y = lean.y + e.y, z = lean.z + e.z })
    local shift = { x = back.x - e.x, y = back.y - e.y, z = back.z - e.z }
    return orientation, position, shift
end

return WeaponView
