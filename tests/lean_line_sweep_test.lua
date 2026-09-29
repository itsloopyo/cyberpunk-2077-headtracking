-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Lean line sweep self-test. Runnable under stock lua.
--
-- The cases are cameraunlock-core's own (cpp/tests/lean_line_sweep_tests.cpp),
-- one for one, against the same small analytic world of boxes and walls. The
-- case the sweep exists for is the door frame edge: one line down the middle of
-- the lean passes it and reports clear.

package.path = "./?.lua;./modules/?.lua;" .. package.path
local LeanClamp = require("modules.lean_clamp")
local LeanLineSweep = require("modules.lean_line_sweep")

local function check(cond, label)
    if not cond then error("FAIL " .. label, 2) end
end

local function near(a, b, eps)
    return math.abs(a - b) <= (eps or 1e-4)
end

local function v(x, y, z) return { x = x, y = y, z = z } end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

-- Slab test. A ray starting inside a box does not hit it, as with a physics
-- engine's cast against a solid it starts in.
local function castBox(b, s, d, length)
    local tmin, tmax, axis = 0.0, length, nil
    local so, dd = { s.x, s.y, s.z }, { d.x, d.y, d.z }
    local lo, hi = { b.min.x, b.min.y, b.min.z }, { b.max.x, b.max.y, b.max.z }
    for i = 1, 3 do
        if math.abs(dd[i]) < 1e-9 then
            if so[i] < lo[i] or so[i] > hi[i] then return nil end
        else
            local t1, t2 = (lo[i] - so[i]) / dd[i], (hi[i] - so[i]) / dd[i]
            if t1 > t2 then t1, t2 = t2, t1 end
            if t1 > tmin then tmin, axis = t1, i end
            if t2 < tmax then tmax = t2 end
            if tmin > tmax then return nil end
        end
    end
    if axis == nil then return nil end
    return tmin, v(axis == 1 and 1 or 0, axis == 2 and 1 or 0, axis == 3 and 1 or 0)
end

local function castWall(w, s, d, length)
    local denom = dot(w.normal, d)
    if denom >= 0 then return nil end
    local t = (w.offset - dot(w.normal, s)) / denom
    if t < 0 or t > length then return nil end
    return t, w.normal
end

local function newWorld()
    local world = { boxes = {}, walls = {}, fail = false, casts = 0 }
    world.cast = function(sx, sy, sz, dx, dy, dz, length)
        world.casts = world.casts + 1
        if world.fail then return false end
        local s, d = v(sx, sy, sz), v(dx, dy, dz)
        local best, bn
        local function take(t, n)
            if t and (not best or t < best) then best, bn = t, n end
        end
        for _, b in ipairs(world.boxes) do take(castBox(b, s, d, length)) end
        for _, w in ipairs(world.walls) do take(castWall(w, s, d, length)) end
        if not best then return true, false, 0, 0, 0, 0 end
        return true, true, best, bn.x, bn.y, bn.z
    end
    return world
end

local RADIUS = 0.1

-- The clamp's call: the lean plus the skin.
local function ask(world, lean, dir)
    local q = LeanLineSweep.query(world.cast, RADIUS)
    local o = q(v(0, 0, 0), dir or v(0, 0, 1), lean + RADIUS)
    return { queried = o.queried, blocked = o.blocked, distance = o.distance }
end

print("== lean line sweep ==")

do
    local world = newWorld()
    local o = ask(world, 0.3)
    check(o.queried and not o.blocked, "open space is a definite clear path")
    check(world.casts == 1 + 2 * 8, "one centre ray, and a probe and a ray per ring slot")
end

do
    local world = newWorld()
    world.walls[1] = { normal = v(0, 0, -1), offset = -0.35 }  -- plane z = 0.35
    local o = ask(world, 0.3)
    check(o.blocked, "a wall 0.35 ahead blocks a 0.3 lean with a 0.1 radius")
    check(near(o.distance - RADIUS, 0.25), "the centre stops a radius short of the wall")
    world.walls[1].offset = -1.0
    check(not ask(world, 0.3).blocked, "a wall past the lean and the radius is clear")
end

do
    local world = newWorld()
    -- Plane through (0, 0, 0.5) with its normal 60 degrees off the lean.
    local n = v(math.sin(1.04719755), 0, -math.cos(1.04719755))
    world.walls[1] = { normal = n, offset = dot(n, v(0, 0, 0.5)) }
    local o = ask(world, 0.45)
    check(o.blocked and near(o.distance - 0.1, 0.3, 1e-3), "an oblique wall stops the centre at radius / cos")
    local at = v(0, 0, o.distance - 0.1)
    check(near(math.abs(dot(n, at) - world.walls[1].offset), 0.1, 1e-3),
        "the stopped centre is a radius off the plane")
end

do
    local world = newWorld()
    -- A door frame: its face at z = 0.2, starting 5 cm to the side of the lean.
    world.boxes[1] = { min = v(0.05, -1, 0.2), max = v(1, 1, 0.4) }
    local _, hit = world.cast(0, 0, 0, 0, 0, 1, 1.0)
    check(not hit, "one line down the middle of the lean misses the frame")
    local o = ask(world, 0.3)
    check(o.blocked, "the ring catches the frame edge beside the centre line")
    check(o.distance - 0.1 <= 0.2 + 1e-4, "the eye stops before the frame's face")
end

do
    local world = newWorld()
    -- A wall running along the lean, 4 cm to the side: closer than the radius.
    world.boxes[1] = { min = v(0.04, -1, -1), max = v(1, 1, 2) }
    local o = ask(world, 0.3)
    check(o.queried and not o.blocked, "a lean parallel to a wall already beside the eye is not blocked by it")
end

do
    local world = newWorld()
    world.fail = true
    check(not ask(world, 0.3).queried, "a cast that cannot run leaves the query unanswered")
end

do
    local world = newWorld()
    world.boxes[1] = { min = v(0.05, -1, 0.2), max = v(1, 1, 0.4) }
    local clamp = LeanClamp.new(RADIUS, 0.9)
    local out = clamp:apply(v(0, 0, 0), v(0, 0, 0.3), 0.016, LeanLineSweep.query(world.cast, RADIUS))
    check(clamp:inContact() and out.z <= 0.2 + 1e-4 and out.z > 0,
        "the clamp with the sweep stops the lean short of an edge a line misses")
end

do
    local world = newWorld()
    world.walls[1] = { normal = v(0, -1, 0), offset = -0.3 }  -- ceiling at y = 0.3
    local o = ask(world, 0.25, v(0, 1, 0))
    check(o.blocked and near(o.distance - 0.1, 0.2), "a lean straight up stops a radius under the ceiling")
end

print("== lean line sweep OK ==")
