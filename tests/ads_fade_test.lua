-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- ADS transition self-test: the fade shape and what it blends. Runnable under
-- stock lua.
--
-- The cases are the ones cameraunlock-core pins for its own copies
-- (cpp/tests/ads_tests.cpp), because the transition is a cross-mod contract and
-- a case only one language checks is a case the two can drift apart on. The
-- durations themselves are pinned separately by core_constants_test.lua.
--
-- What is easy to get wrong here, and none of it is visible from the gate or
-- settings suites:
--   * the entry frame must not step. A transition that starts at 0.9 instead of
--     1.0 is a jolt in the direction the fade exists to remove.
--   * a player who taps aim interrupts the transition half way, and it has to
--     turn round from where it is rather than from where it started.
--   * roll comes from the ABSOLUTE pose in the tracked modes and is never
--     interpolated toward the relative one. It rides the fade in "paused" only,
--     and only because this mod hands the camera back at the end of the ramp -
--     see the ROLL note in modules/ads_blend.lua.
--   * abs and rel carry different rolls in every blend case below. With them
--     equal, a blend reading roll from the wrong pose passes the whole suite.

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("FAIL %s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

local function assert_near(actual, expected, label, tol)
    tol = tol or 1e-6
    if type(actual) ~= "number" or math.abs(actual - expected) > tol then
        error(string.format("FAIL %s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

package.path = "./?.lua;./modules/?.lua;" .. package.path
local AdsFade = require("modules.ads_fade")
local AdsBlend = require("modules.ads_blend")

print("== ads fade ==")

local LOWER = AdsFade.LOWER_S
local RAISE = AdsFade.RAISE_S

-- Endpoints and shape.
do
    local fade = AdsFade.new()
    assert_near(fade:update(false, 1.0), 1.0, "the hip is full scale")

    -- The frame the sights start coming up is still full scale: the transition
    -- eases out of rest, it does not step.
    assert_near(fade:update(true, 0.0), 1.0, "the entry frame does not step")
    assert_near(fade:update(true, LOWER / 2), 0.5, "smoothstep is symmetric about the half", 1e-3)
    assert_near(fade:update(true, LOWER), 0.0, "it reaches zero by sights-up")
    assert_eq(fade:isSightsUp(), true, "and says so, which is what closes the gate")
    assert_near(fade:update(true, LOWER + 5.0), 0.0, "and holds there while the sights are up")

    assert_near(fade:update(false, 10.0), 0.0, "lowering the weapon does not step either")
    assert_eq(fade:isSightsUp(), false, "the gate reopens as soon as the sights start dropping")
    assert_near(fade:update(false, 10.0 + RAISE), 1.0, "and it comes back in full")
end

-- The ride out never reverses.
do
    local fade = AdsFade.new()
    fade:update(true, 0.0)
    local last = 1.1
    local t = 0.0
    while t <= LOWER do
        local now = fade:update(true, t)
        if now > last + 1e-4 then
            error(string.format("FAIL the ride out reversed at t=%.3f: %s after %s",
                t, tostring(now), tostring(last)))
        end
        last = now
        t = t + 0.005
    end
    -- Landed separately rather than off the loop's last step: t accumulates in
    -- floating point and stops just short of LOWER, where the curve is still a
    -- few thousandths above zero.
    assert_near(fade:update(true, LOWER), 0.0, "the ride out ends at zero")
end

-- A player who taps aim interrupts the transition half way. It has to turn
-- round from where it is, not from where it started, or the view jumps by the
-- part that had already faded.
do
    local fade = AdsFade.new()
    fade:update(true, 0.0)
    local half = fade:update(true, LOWER / 2)
    local resumed = fade:update(false, LOWER / 2)
    -- Continuity, to the same tolerance as everything else here. A loose bound
    -- is worse than none: the previous 0.55 could not be violated by any
    -- implementation returning a value in [0,1], so it passed while the reversal
    -- stepped by a full half.
    assert_near(resumed, half, "an interrupted transition is continuous")
    assert_near(fade:update(false, LOWER / 2 + RAISE), 1.0, "and it still finishes")
end

-- The worst reversal is the earliest one: a tap releases the aim button a frame
-- after pressing it, with the pose still ~100% applied.
do
    local fade = AdsFade.new()
    fade:update(true, 0.0)
    local barely = fade:update(true, 0.001)
    local resumed = fade:update(false, 0.001)
    assert_near(resumed, barely, "a one-frame tap does not step the pose")
    assert_near(fade:update(false, 0.001 + RAISE), 1.0, "and returns to the hip")
end

-- An interrupted leg travels at the same RATE as a whole one, so a short
-- reversal finishes quickly rather than taking the full duration to cover a
-- fraction of the distance.
do
    local fade = AdsFade.new()
    fade:update(true, 0.0)
    local quarter = fade:update(true, LOWER * 0.25)
    fade:update(false, LOWER * 0.25)
    local remaining = RAISE * (1.0 - quarter)
    assert_near(fade:update(false, LOWER * 0.25 + remaining), 1.0,
        "the ride back is scaled to the distance left")
end

-- Reset is for the suppressions that are not ADS: menu, loading, cinematic,
-- master toggle, tracker dropout. The next aim starts clean.
do
    local fade = AdsFade.new()
    fade:update(true, 0.0)
    fade:update(true, LOWER)
    fade:reset()
    assert_eq(fade:isSightsUp(), false, "Reset drops the sights-up flag")
    assert_near(fade:update(false, 5.0), 1.0, "Reset drops straight back to the hip")
end

print("== ads blend ==")

local function pose(yaw, pitch, roll, x, y, z)
    return { yaw = yaw, pitch = pitch, roll = roll, x = x, y = y, z = z }
end

-- At the hip every mode is the head pose untouched. abs and rel carry DIFFERENT
-- rolls throughout this section: with them equal, a blend that reads roll from
-- the wrong pose entirely passes every case.
do
    local abs = pose(-12, 5, 3, 1, 2, 3)
    local rel = pose(0, 0, 7, 0, 0, 0)
    for _, mode in ipairs({ "paused", "marker", "tracked" }) do
        local out = AdsBlend.blend(mode, 1.0, abs, rel)
        assert_near(out.yaw, -12, mode .. " hip yaw")
        assert_near(out.pitch, 5, mode .. " hip pitch")
        assert_near(out.roll, 3, mode .. " hip roll")
        assert_near(out.z, 3, mode .. " hip z")
    end
end

-- Sights fully up in "paused": the view is the game's own again.
do
    local out = AdsBlend.blend("paused", 0.0, pose(-12, 5, 3, 1, 2, 3), pose(0, 0, 7, 0, 0, 0))
    assert_near(out.yaw, 0, "paused drops yaw")
    assert_near(out.pitch, 0, "paused drops pitch")
    assert_near(out.x, 0, "paused drops the lean x")
    assert_near(out.y, 0, "paused drops the lean y")
    assert_near(out.z, 0, "paused drops the lean z")
    -- Faded rather than held: this mod hands the camera back at the end of the
    -- ramp, and Camera:suspend() would cut a held tilt in one frame there.
    assert_near(out.roll, 0, "paused rides the tilt down with the rest")
end

-- And halfway through, every axis is half way down together.
do
    local out = AdsBlend.blend("paused", 0.5, pose(-20, 8, 3, 0, 0, 4), pose(0, 0, 7, 0, 0, 0))
    assert_near(out.yaw, -10, "paused fades yaw")
    assert_near(out.pitch, 4, "paused fades pitch")
    assert_near(out.z, 2, "the lean rides the same fade as the rotation")
    assert_near(out.roll, 1.5, "and the tilt rides it too")
end

-- The tracked modes land on the entry-relative pose, whose roll is the absolute
-- one already, so the two branches agree about roll and about nothing else.
do
    local abs = pose(-12, 5, 3, 1, 2, 3)
    local rel = pose(-4, 2, 7, 0.5, 0.5, 1)
    for _, mode in ipairs({ "marker", "tracked" }) do
        local out = AdsBlend.blend(mode, 0.0, abs, rel)
        assert_near(out.yaw, -4, mode .. " lands on the relative yaw")
        assert_near(out.pitch, 2, mode .. " lands on the relative pitch")
        assert_near(out.x, 0.5, mode .. " lands on the relative x")
        assert_near(out.z, 1, mode .. " lands on the relative z")
        assert_near(out.roll, 3, mode .. " roll is the absolute one, not the relative one")
    end
end

-- Mid-fade, which is the only place the interpolation curve itself is
-- observable. Tested at the endpoints alone, any curve at all passes.
do
    local abs = pose(-12, 5, 3, 1, 2, 3)
    local rel = pose(-4, 2, 7, 0.5, 0.5, 1)
    local out = AdsBlend.blend("tracked", 0.25, abs, rel)
    assert_near(out.yaw, -12 * 0.25 + -4 * 0.75, "tracked yaw is linear in the scale")
    assert_near(out.pitch, 5 * 0.25 + 2 * 0.75, "tracked pitch is linear in the scale")
    assert_near(out.x, 1 * 0.25 + 0.5 * 0.75, "tracked x is linear in the scale")
    assert_near(out.roll, 3, "and roll is still untouched half way through")
end

-- Position arrives only on the frames a packet did. A nil has to pass through
-- as a nil: blending it against a zero would drag the applied lean toward
-- centre on every frame without a packet, at the tracker's own rate.
do
    local out = AdsBlend.blend("tracked", 0.5,
        pose(-12, 5, 3, nil, nil, nil), pose(-4, 2, 3, nil, nil, nil))
    assert_eq(out.x, nil, "a frame with no packet blends no position")
    assert_near(out.yaw, -8, "rotation still blends on a frame with no packet")

    local paused = AdsBlend.blend("paused", 0.5,
        pose(-12, 5, 3, nil, nil, nil), pose(0, 0, 3, nil, nil, nil))
    assert_eq(paused.x, nil, "and the same in paused")
    assert_near(paused.yaw, -6, "paused still fades rotation on a frame with no packet")
end

-- Before the first sample the interpolator returns nil for the whole rotation
-- triple. Nothing to blend and nothing to invent.
do
    local out = AdsBlend.blend("tracked", 0.5,
        pose(nil, nil, nil, 1, 2, 3), pose(nil, nil, nil, 0.5, 0.5, 1))
    assert_eq(out.yaw, nil, "no rotation yet blends to no rotation")
    assert_near(out.x, 0.75, "position still blends before the first rotation sample")
end

print("== ADS transition OK ==")
