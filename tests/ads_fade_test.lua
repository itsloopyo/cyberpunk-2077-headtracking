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
--   * the blend eases the lean and never touches rotation, roll included:
--     head tracking carries straight on through the aim.

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
    assert_near(fade:update(true, LOWER + 5.0), 0.0, "and holds there while the sights are up")

    assert_near(fade:update(false, 10.0), 0.0, "lowering the weapon does not step either")
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
    assert_near(fade:update(false, 5.0), 1.0, "Reset drops straight back to the hip")
end

print("== ads blend ==")

local function pose(yaw, pitch, roll, x, y, z)
    return { yaw = yaw, pitch = pitch, roll = roll, x = x, y = y, z = z }
end

-- At the hip the pose passes through untouched.
do
    local out = AdsBlend.blend(1.0, pose(-12, 5, 3, 1, 2, 3))
    assert_near(out.yaw, -12, "hip yaw")
    assert_near(out.pitch, 5, "hip pitch")
    assert_near(out.roll, 3, "hip roll")
    assert_near(out.x, 1, "hip x")
    assert_near(out.z, 3, "hip z")
end

-- On the sights rotation is untouched, roll included, and the lean is gone.
do
    local out = AdsBlend.blend(0.0, pose(-12, 5, 3, 1, 2, 3))
    assert_near(out.yaw, -12, "yaw is untouched on the sights")
    assert_near(out.pitch, 5, "pitch is untouched on the sights")
    assert_near(out.roll, 3, "roll is untouched on the sights")
    assert_near(out.x, 0, "the lean x is gone on the sights")
    assert_near(out.y, 0, "the lean y is gone on the sights")
    assert_near(out.z, 0, "the lean z is gone on the sights")
end

-- Mid-fade the lean is scaled and rotation is still untouched.
do
    local out = AdsBlend.blend(0.25, pose(-12, 5, 3, 2, 2, 4))
    assert_near(out.x, 0.5, "the lean x rides the fade")
    assert_near(out.z, 1, "the lean z rides the fade")
    assert_near(out.yaw, -12, "yaw is untouched mid-fade")
end

-- Position arrives only on the frames a packet did. A nil has to pass through
-- as a nil: scaling it against a zero would drag the applied lean toward
-- centre on every frame without a packet.
do
    local out = AdsBlend.blend(0.5, pose(-12, 5, 3, nil, nil, nil))
    assert_eq(out.x, nil, "a frame with no packet carries no position")
    assert_near(out.yaw, -12, "rotation still passes on a frame with no packet")
end

-- Before the first sample the interpolator returns nil for the whole rotation
-- triple. Nothing to invent.
do
    local out = AdsBlend.blend(0.5, pose(nil, nil, nil, 1, 2, 3))
    assert_eq(out.yaw, nil, "no rotation yet passes as no rotation")
    assert_near(out.x, 0.5, "position still eases before the first rotation sample")
end

print("== ADS transition OK ==")
