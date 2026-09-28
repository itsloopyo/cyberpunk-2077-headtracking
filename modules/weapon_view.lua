-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Weapon View Module
--
-- The weapon is drawn in its own pass, magnified by its own zoom: with a scope
-- up the camera zooms the world by zoomOverrideValue and the weapon by
-- zoomWeaponOverrideValue (1.70 and 1.96 on the Grad's long scope). Without
-- head tracking that costs nothing, because the weapon sits on the view axis.
-- With the head turned the weapon's axis is off to one side, and the weapon
-- pass throws it further across the frame than the world pass throws the aim
-- point, by the ratio of the two zooms. The scope's lens shows the frame behind
-- it, so its dot then sits on something other than what the round will hit.
--
-- The fix turns the weapon about the eye so its sight line comes out where the
-- world pass would have drawn it: in the rendered camera's frame the lateral
-- components of the direction to the sight line are divided by the ratio and
-- the forward one kept, and the weapon takes the shortest arc between the two.
-- The round is untouched; it leaves along the clean aim either way.
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
-- a with its lateral part shrunk.
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

--- The magnification one of the camera's zoom channels gives: its zoom blended
--- toward the override value by the override weight.
function WeaponView.magnification(zoom, weight, value)
    return zoom * (1 - weight) + value * weight
end

--- The world-space turn to give the weapon, about the rendered eye.
---
--- The sight line runs from the clean eye along the clean aim. The point on it
--- at the weapon's depth is where the weapon has to appear, so the turn is taken
--- on the direction from the rendered eye to that point. With the eye on the
--- sight line (sights locked) that is the aim itself; with the eye leaned off it
--- (true free look) it is the parallax the weapon pass would otherwise magnify.
--- @param aim table Unit clean aim direction, world
--- @param axes table Rendered camera's world axes {X, Y, Z}: right, forward, up
--- @param eye table Rendered eye, world
--- @param sight_origin table Where the sight line starts: the clean eye, world
--- @param weapon_pos table Weapon entity origin, world
--- @param ratio number Weapon magnification over world magnification
--- @return table quaternion
function WeaponView.turn(aim, axes, eye, sight_origin, weapon_pos, ratio)
    local to_weapon = {
        x = weapon_pos.x - sight_origin.x,
        y = weapon_pos.y - sight_origin.y,
        z = weapon_pos.z - sight_origin.z,
    }
    local depth = dot(to_weapon, aim)
    local v = {
        x = sight_origin.x + aim.x * depth - eye.x,
        y = sight_origin.y + aim.y * depth - eye.y,
        z = sight_origin.z + aim.z * depth - eye.z,
    }
    local cx, cy, cz = dot(v, axes.X) / ratio, dot(v, axes.Y), dot(v, axes.Z) / ratio
    local w = {
        x = axes.X.x * cx + axes.Y.x * cy + axes.Z.x * cz,
        y = axes.X.y * cx + axes.Y.y * cy + axes.Z.y * cz,
        z = axes.X.z * cx + axes.Y.z * cy + axes.Z.z * cz,
    }
    return arc(normalize(v), normalize(w))
end

--- A world turn about the eye, as the local transform of a part sitting at the
--- weapon entity's origin with an identity local transform.
--- @return table position, table quaternion
function WeaponView.toLocal(turn, eye, weapon_pos, weapon_quat)
    local rel = { x = weapon_pos.x - eye.x, y = weapon_pos.y - eye.y, z = weapon_pos.z - eye.z }
    local moved = qrot(turn, rel)
    local inv = qconj(weapon_quat)
    local pos = qrot(inv, { x = moved.x - rel.x, y = moved.y - rel.y, z = moved.z - rel.z })
    return pos, qmul(qmul(inv, turn), weapon_quat)
end

return WeaponView
