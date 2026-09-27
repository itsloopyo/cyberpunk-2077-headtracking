-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Lean clamp self-test. Runnable under stock lua.
--
-- The cases are cameraunlock-core's own (cpp/tests/lean_clamp_tests.cpp), one
-- for one, because modules/lean_clamp.lua is a port of that policy and a case
-- only one language checks is a case the two can drift apart on. The two that
-- matter most are the asymmetry between tightening and releasing, and the
-- difference between a query that answered "clear" and one that could not
-- answer at all.

package.path = "./?.lua;./modules/?.lua;" .. package.path
local LeanClamp = require("modules.lean_clamp")

local function check(cond, label)
    if not cond then error("FAIL " .. label, 2) end
end

local function near(a, b, eps)
    return math.abs(a - b) <= (eps or 1e-4)
end

local function v(x, y, z) return { x = x, y = y, z = z } end
local function mag(o) return math.sqrt(o.x * o.x + o.y * o.y + o.z * o.z) end
local ZERO = v(0, 0, 0)

local function world(queried, blocked, distance)
    local w = { queried = queried, blocked = blocked, distance = distance or 0, calls = 0 }
    w.query = function()
        w.calls = w.calls + 1
        return { queried = w.queried, blocked = w.blocked, distance = w.distance }
    end
    return w
end

print("== lean clamp ==")

do
    local clamp = LeanClamp.new(0.10, 0.9)
    local w = world(true, false)
    local out = clamp:apply(ZERO, v(0, 0, 0.4), 0.016, w.query)
    check(w.calls == 1, "a lean runs the query exactly once")
    check(near(out.z, 0.4), "a clear path leaves the lean at full magnitude")
    check(not clamp:inContact(), "a clear path reports no contact")
end

do
    local clamp = LeanClamp.new(0.10, 0.9)
    local w = world(true, true, 0.25)
    local out = clamp:apply(ZERO, v(0.4, 0, 0), 0.016, w.query)
    check(near(out.x, 0.15), "a blocked lean stops at the hit distance minus the skin")
    check(clamp:inContact(), "a blocked lean reports contact")
end

do
    -- 0.3 / 0.4 / 0.0, magnitude 0.5. Allowed magnitude is 0.30 - 0.10 = 0.20,
    -- so the components scale by 0.4.
    local clamp = LeanClamp.new(0.10, 0.9)
    local w = world(true, true, 0.30)
    local out = clamp:apply(ZERO, v(0.3, 0.4, 0), 0.016, w.query)
    check(near(mag(out), 0.20), "the clamped lean has the allowed magnitude")
    check(near(out.x, 0.12) and near(out.y, 0.16), "the clamped lean keeps its direction")
end

do
    local clamp = LeanClamp.new(0.10, 0.9)
    local w = world(true, true, 0.04)
    local tight = clamp:apply(ZERO, v(0.3, 0, 0), 0.016, w.query)
    check(near(mag(tight), 0), "a surface inside the skin allows no lean")
    clamp:reset()
    w.distance = 0
    local inside = clamp:apply(ZERO, v(0.3, 0, 0), 0.016, w.query)
    check(near(mag(inside), 0), "an eye already inside geometry allows no lean")
end

do
    local clamp = LeanClamp.new(0.10, 0.9)
    local w = world(true, false)
    clamp:apply(ZERO, v(0.4, 0, 0), 0.016, w.query)
    w.blocked, w.distance = true, 0.15
    local out = clamp:apply(ZERO, v(0.4, 0, 0), 0.016, w.query)
    check(near(out.x, 0.05), "a wall appearing tightens the allowance in one frame")
end

do
    local clamp = LeanClamp.new(0.10, 0.9)
    local w = world(true, true, 0.15)
    clamp:apply(ZERO, v(0.4, 0, 0), 0.016, w.query)
    w.blocked = false
    local first = clamp:apply(ZERO, v(0.4, 0, 0), 0.016, w.query)
    check(first.x > 0.05, "the allowance opens once the obstruction clears")
    check(first.x < 0.4, "the allowance does not jump straight back to full")
    check(clamp:inContact(), "the view is still held short while the release runs")
    for _ = 1, 240 do clamp:apply(ZERO, v(0.4, 0, 0), 0.016, w.query) end
    local settled = clamp:apply(ZERO, v(0.4, 0, 0), 0.016, w.query)
    check(near(settled.x, 0.4, 1e-3), "the release converges on the full lean")
    check(not clamp:inContact(), "contact clears once the release has converged")
end

do
    local clamp = LeanClamp.new(0.10, 0.9)
    local w = world(false, false)
    local out = clamp:apply(ZERO, v(0.4, 0, 0), 0.016, w.query)
    check(near(out.x, 0.4), "a failed query passes the lean through unclamped")
    check(clamp:lastQueryFailed(), "a failed query is reported to the caller")
    check(not clamp:inContact(), "a failed query is not reported as contact")
    w.queried = true
    clamp:apply(ZERO, v(0.4, 0, 0), 0.016, w.query)
    check(not clamp:lastQueryFailed(), "the failure flag clears once the query works again")
end

do
    local clamp = LeanClamp.new(0.10, 0.9)
    local w = world(true, true, 0.12)
    clamp:apply(ZERO, v(0.4, 0, 0), 0.016, w.query)
    local calls_before = w.calls
    local neutral = clamp:apply(ZERO, ZERO, 0.016, w.query)
    check(near(mag(neutral), 0), "a neutral pose produces no offset")
    check(w.calls == calls_before, "a neutral pose does not run the query")
    w.blocked = false
    local out = clamp:apply(ZERO, v(0.4, 0, 0), 0.016, w.query)
    check(near(out.x, 0.4), "the lean after a neutral pose is not rationed by the old wall")
end

do
    -- Centimetres, as an Unreal mod passes: the settle tolerance is relative.
    local clamp = LeanClamp.new(10.0, 0.9)
    local w = world(true, false)
    local followed, ever_in_contact = true, false
    for frame = 1, 30 do
        local reach = 30.0 * (frame / 30.0)
        local out = clamp:apply(ZERO, v(reach, 0, 0), 0.016, w.query)
        if not near(out.x, reach, 1e-3) then followed = false end
        if clamp:inContact() then ever_in_contact = true end
    end
    check(followed, "a lean growing through open space is never held back")
    check(not ever_in_contact, "and is never reported as contact")
end

do
    local clamp = LeanClamp.new(10.0, 0.9)
    local w = world(true, true, 15.0)
    clamp:apply(ZERO, v(30, 0, 0), 0.016, w.query)
    check(clamp:inContact(), "a 30cm lean into a wall 15cm away is held back")
    w.blocked = false
    for _ = 1, 120 do clamp:apply(ZERO, v(30, 0, 0), 0.016, w.query) end
    check(not clamp:inContact(), "the release settles within two seconds at centimetre scale")
end

do
    local clamp = LeanClamp.new(0.10, 0.9)
    local w = world(true, true, 0.12)
    clamp:apply(ZERO, v(0.4, 0, 0), 0.016, w.query)
    check(clamp:inContact(), "the clamp is in contact before the reset")
    clamp:reset()
    check(not clamp:inContact(), "reset clears the contact flag")
    w.blocked = false
    local out = clamp:apply(ZERO, v(0.4, 0, 0), 0.016, w.query)
    check(near(out.x, 0.4), "the first lean after a reset takes its answer outright")
end

print("== Lean clamp OK ==")
