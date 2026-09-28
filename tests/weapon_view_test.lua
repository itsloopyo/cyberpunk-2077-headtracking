-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Weapon view self-test. Runnable under stock lua.
--
-- The property that matters: after the turn, the weapon pass, projecting with
-- the weapon's magnification, draws the sight line exactly where the world pass
-- draws it with the world's. Checked on single-axis and combined head poses,
-- with the eye on the sight line and leaned off it, and through the local
-- transform the parts are actually written with.

package.path = "./?.lua;./modules/?.lua;" .. package.path
local WeaponView = require("modules.weapon_view")

local function check(cond, label)
    if not cond then error("FAIL " .. label, 2) end
end

local function near(a, b, eps)
    return math.abs(a - b) <= (eps or 1e-6)
end

local function v(x, y, z) return { x = x, y = y, z = z } end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
local function scale(a, s) return v(a.x * s, a.y * s, a.z * s) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

local function qmul(a, b)
    return {
        i = a.r * b.i + a.i * b.r + a.j * b.k - a.k * b.j,
        j = a.r * b.j - a.i * b.k + a.j * b.r + a.k * b.i,
        k = a.r * b.k + a.i * b.j - a.j * b.i + a.k * b.r,
        r = a.r * b.r - a.i * b.i - a.j * b.j - a.k * b.k,
    }
end
local function qrot(q, p)
    local o = qmul(qmul(q, { i = p.x, j = p.y, k = p.z, r = 0 }), { i = -q.i, j = -q.j, k = -q.k, r = q.r })
    return v(o.i, o.j, o.k)
end
local function axisAngle(axis, deg)
    local h = math.rad(deg) / 2
    return { i = axis.x * math.sin(h), j = axis.y * math.sin(h), k = axis.z * math.sin(h), r = math.cos(h) }
end
local function axesOf(q)
    return { X = qrot(q, v(1, 0, 0)), Y = qrot(q, v(0, 1, 0)), Z = qrot(q, v(0, 0, 1)) }
end

-- Screen position of a world point for a camera with these axes at this eye,
-- with the projection scaled by a magnification.
local function project(point, eye, axes, magnification)
    local d = sub(point, eye)
    local f = dot(d, axes.Y)
    return magnification * dot(d, axes.X) / f, magnification * dot(d, axes.Z) / f
end

local WORLD_ZOOM, WEAPON_ZOOM = 1.6997, 1.9614
local RATIO = WEAPON_ZOOM / WORLD_ZOOM

-- The sight line from `origin` along `aim`, at the weapon's depth, drawn by the
-- weapon pass after the turn, against the same point drawn by the world pass.
local function sightLineError(head, lean, weapon_offset)
    local clean = axisAngle(v(0, 0, 1), 30)          -- the body faces somewhere arbitrary
    local aim = qrot(clean, v(0, 1, 0))
    local origin = v(4, -2, 1.7)
    local weapon_pos = add(origin, qrot(clean, weapon_offset))
    local rendered = qmul(clean, head)
    local axes = axesOf(rendered)
    local eye = add(origin, qrot(rendered, lean))

    local turn = WeaponView.turn(aim, axes, eye, origin, weapon_pos, RATIO)
    local depth = dot(sub(weapon_pos, origin), aim)
    local sight = add(origin, scale(aim, depth))
    local turned = add(eye, qrot(turn, sub(sight, eye)))

    local wx, wz = project(sight, eye, axes, WORLD_ZOOM)
    local gx, gz = project(turned, eye, axes, WEAPON_ZOOM)
    return gx - wx, gz - wz, turn
end

print("== weapon view ==")

do
    check(near(WeaponView.magnification(1.0, 0.0, 1.9614), 1.0), "no weight: the camera's own zoom")
    check(near(WeaponView.magnification(1.0, 1.0, 1.9614), 1.9614), "full weight: the override")
    check(near(WeaponView.magnification(1.0, 0.5, 2.0), 1.5), "half weight: halfway")
end

do
    local origin = v(0, 0, 0)
    local axes = axesOf(axisAngle(v(0, 0, 1), 12))
    local q = WeaponView.turn(v(0, 1, 0), axes, origin, origin, v(0.1, 0.3, -0.1), 1.0)
    check(near(q.r, 1) and near(q.i, 0) and near(q.j, 0) and near(q.k, 0), "equal zooms: no turn")
end

do
    local ex, ez, turn = sightLineError(axisAngle(v(0, 0, 1), 0), v(0, 0, 0), v(-0.05, 0.3, -0.06))
    check(near(ex, 0) and near(ez, 0), "head centred: the sight line is already on the aim")
    check(near(math.abs(turn.r), 1), "head centred: no turn")
end

for _, case in ipairs({
    { "yaw right", axisAngle(v(0, 0, 1), -12) },
    { "yaw left", axisAngle(v(0, 0, 1), 12) },
    { "pitch up", axisAngle(v(1, 0, 0), 8) },
    { "yaw and pitch", qmul(axisAngle(v(0, 0, 1), 15), axisAngle(v(1, 0, 0), -9)) },
    { "yaw, pitch and roll", qmul(qmul(axisAngle(v(0, 0, 1), -20), axisAngle(v(1, 0, 0), 10)), axisAngle(v(0, 1, 0), 14)) },
}) do
    local ex, ez = sightLineError(case[2], v(0, 0, 0), v(-0.05, 0.3, -0.06))
    check(near(ex, 0) and near(ez, 0), "sights locked, " .. case[1] .. ": the weapon pass draws the sight line on the aim")
end

do
    -- Without the turn the weapon pass overshoots by the zoom ratio: the fault.
    local clean_axes = axesOf(axisAngle(v(0, 0, 1), -12))
    local sight = v(0, 0.3, 0)
    local wx = project(sight, v(0, 0, 0), clean_axes, WORLD_ZOOM)
    local gx = project(sight, v(0, 0, 0), clean_axes, WEAPON_ZOOM)
    check(near(gx / wx, RATIO), "untreated, the weapon moves across the frame by the zoom ratio")
end

do
    local head = qmul(axisAngle(v(0, 0, 1), 10), axisAngle(v(1, 0, 0), 5))
    local ex, ez = sightLineError(head, v(0.2, 0.05, -0.08), v(-0.05, 0.3, -0.06))
    check(near(ex, 0) and near(ez, 0), "true free look, leaned eye: the parallax is the world pass's, not magnified")
end

do
    -- The parts are written with a local transform under the weapon entity.
    -- Applied to any point of the weapon it has to give the same world point
    -- as the world turn about the eye.
    local turn = axisAngle(v(0.3, 0.2, 0.93), 1.7)
    local l = math.sqrt(turn.i ^ 2 + turn.j ^ 2 + turn.k ^ 2 + turn.r ^ 2)
    turn = { i = turn.i / l, j = turn.j / l, k = turn.k / l, r = turn.r / l }
    local eye = v(1, 2, 1.7)
    local weapon_pos = v(0.8, 2.2, 1.55)
    local weapon_quat = qmul(axisAngle(v(0, 0, 1), 40), axisAngle(v(1, 0, 0), -15))
    local pos, quat = WeaponView.toLocal(turn, eye, weapon_pos, weapon_quat)
    for _, p in ipairs({ v(0, 0, 0), v(0.1, 0.5, 0.05), v(-0.2, 0.3, 0.1) }) do
        local placed = add(weapon_pos, qrot(weapon_quat, add(pos, qrot(quat, p))))
        local expected = add(eye, qrot(turn, sub(add(weapon_pos, qrot(weapon_quat, p)), eye)))
        check(near(placed.x, expected.x) and near(placed.y, expected.y) and near(placed.z, expected.z),
            "the local transform turns the weapon about the eye")
    end
end

print("weapon view: all checks passed")
