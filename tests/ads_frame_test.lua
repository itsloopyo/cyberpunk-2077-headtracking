-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- ADS per-frame decision self-test. Runnable under stock lua.
--
-- Drives modules/ads_frame.lua over many consecutive frames against the REAL
-- modules/ads_fade.lua, because the two defects this covers are both ordering
-- bugs that only appear across frames. Neither the gate suite nor the blend
-- suite can see them: each is correct in isolation and they are wrong together.
--
--   * the oscillation. "paused" holds the gate open while the fade runs the
--     pose down and closes it behind. Feed the gate's own verdict back in as
--     `aiming` and the fade starts raising the instant it finishes lowering,
--     the gate reopens a frame later, and the pose snaps back to full - about
--     seven times a second, for as long as the trigger is held.
--   * the dead ride back. Drop the entry pose the moment aiming ends and the
--     relative pose becomes the absolute pose, so the 250ms ramp interpolates a
--     value with itself and the view steps by the whole entry offset.
--
-- The gate is modelled the way modules/state.lua actually walks it, which is
-- the one line that matters here: "paused" closes only once the fade says the
-- pose has gone, and reopens as soon as the sights drop.

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
local AdsFrame = require("modules.ads_frame")
local AdsPose = require("modules.ads_pose")
local AdsBlend = require("modules.ads_blend")

print("== ads frame ==")

local FRAME_S = 1 / 60

-- The gate, as modules/state.lua walks it. `suppression` stands for a menu, a
-- load, a cinematic or the master toggle: every reason that outranks ADS and
-- reports itself instead.
local function makeGate(fade)
    return function(mode, sights, suppression)
        if suppression then return false, "menu", false end
        if sights then
            if mode == "paused" and fade:isSightsUp() then
                return false, "ads", true
            end
            return true, "allowed", true
        end
        return true, "allowed", false
    end
end

--- Run `frames` frames and return the trace.
--- @param mode string
--- @param script function(i) -> sights, suppression
local function run(mode, frames, script)
    local fade = AdsFade.new()
    local frame = AdsFrame.new(fade)
    local pose = AdsPose.new()
    local gate = makeGate(fade)

    local trace = {}
    local now = 0.0
    for i = 1, frames do
        now = now + FRAME_S
        local sights, suppression = script(i)
        local allowed, reason, aiming = gate(mode, sights, suppression)
        local scale = frame:update(mode, aiming, allowed, reason == "ads", now)

        -- The head is held 20 degrees off centre for the whole run, which is
        -- what makes a snap visible as a number.
        local applied
        if allowed then
            local ry, rp, rr = pose:update(frame.pose_holds, 20.0, 0.0, 0.0)
            local blended = AdsBlend.blend(mode, scale,
                { yaw = 20.0, pitch = 0.0, roll = 0.0 },
                { yaw = ry, pitch = rp, roll = rr })
            applied = blended.yaw
        else
            -- The gate is shut: the mod has handed the camera back and nothing
            -- is written this frame.
            applied = 0.0
        end

        trace[i] = { allowed = allowed, reason = reason, scale = scale, applied = applied }
    end
    return trace
end

-- The largest single-frame move the ramp itself can make: smoothstep peaks at a
-- slope of 1.5, so over `duration` seconds a 20 degree pose moves at most
-- 20 * 1.5 * frame / duration in one frame. Derived rather than guessed, so the
-- bound stays meaningful if a duration or the frame rate changes - and so it
-- cannot be quietly loosened until it stops catching anything. The defect it
-- exists for moved the full 20 degrees in one frame, which is 6x this.
local function rampStepBound(duration)
    return 20.0 * 1.5 * FRAME_S / duration * 1.15
end

local function maxStep(trace, from, to)
    local worst, at = 0.0, from
    for i = from + 1, to do
        local step = math.abs(trace[i].applied - trace[i - 1].applied)
        if step > worst then worst, at = step, i end
    end
    return worst, at
end

-- "paused": the pose eases off once and the gate closes behind it, and neither
-- of them changes its mind again for as long as the sights are up.
do
    local trace = run("paused", 120, function() return true, false end)

    local closes = 0
    for i = 2, #trace do
        if trace[i - 1].allowed and not trace[i].allowed then closes = closes + 1 end
    end
    assert_eq(closes, 1, "paused closes the gate exactly once in a held aim")

    for i = 1, #trace do
        if not trace[i].allowed then
            assert_eq(trace[i].reason, "ads", "and it closes for the ADS reason")
        end
    end
    assert_eq(trace[#trace].allowed, false, "and it is still closed at the end of the aim")

    -- The oscillation showed up as a full 20 degree step every ~9 frames.
    local worst = maxStep(trace, 1, #trace)
    if worst > rampStepBound(AdsFade.LOWER_S) then
        error(string.format("FAIL paused snapped the pose by %.2f degrees", worst))
    end

    -- Monotone down to zero: the transition rides out, it does not wobble.
    for i = 2, #trace do
        if trace[i].allowed and trace[i].applied > trace[i - 1].applied + 1e-4 then
            error(string.format("FAIL paused pose rose at frame %d: %.4f after %.4f",
                i, trace[i].applied, trace[i - 1].applied))
        end
    end
end

-- Lowering the weapon reopens the gate and rides the pose back in.
do
    local trace = run("paused", 90, function(i) return i <= 30, false end)
    assert_eq(trace[30].allowed, false, "still suppressed on the last aiming frame")
    assert_eq(trace[31].allowed, true, "the gate reopens the frame the sights drop")
    assert_near(trace[#trace].applied, 20.0, "and the pose is back in full", 1e-3)

    local worst = maxStep(trace, 31, #trace)
    if worst > rampStepBound(AdsFade.RAISE_S) then
        error(string.format("FAIL the ride back stepped by %.2f degrees", worst))
    end
end

-- "tracked": the gate never closes, the entry pose puts the view on the aim,
-- and lowering the weapon RAMPS back rather than stepping. The entry pose being
-- dropped a frame early is what made this a step.
do
    local trace = run("tracked", 90, function(i) return i <= 30, false end)

    for i = 1, #trace do
        assert_eq(trace[i].allowed, true, "tracked keeps the gate open throughout")
    end
    assert_near(trace[30].applied, 0.0, "the entry pose holds the view on the aim", 1e-3)
    assert_near(trace[#trace].applied, 20.0, "and the absolute pose comes back", 1e-3)

    local worst, at = maxStep(trace, 31, #trace)
    if worst > rampStepBound(AdsFade.RAISE_S) then
        error(string.format("FAIL tracked stepped by %.2f degrees at frame %d", worst, at))
    end

    -- A ramp, not a step: the return has to take real frames.
    local moved = 0
    for i = 31, #trace do
        if math.abs(trace[i].applied - trace[i - 1].applied) > 1e-4 then moved = moved + 1 end
    end
    if moved < 5 then
        error("FAIL the ride back completed in " .. moved .. " frames, so it is a step")
    end
end

-- A menu mid-aim is a real suppression: the transition resets, so the aim that
-- resumes after it re-enters from the hip rather than from a frozen offset.
do
    local trace = run("paused", 60, function(i) return true, i >= 20 and i <= 40 end)
    assert_eq(trace[25].reason, "menu", "the menu outranks ADS in the reported reason")
    -- Frame 41 is the first frame back in gameplay with the sights still up, and
    -- it has to start the transition again from full scale.
    assert_near(trace[41].scale, 1.0, "the transition re-enters from the hip after a menu")
end

-- Cycling to "paused" while already aiming must not strand the entry pose.
do
    local fade = AdsFade.new()
    local frame = AdsFrame.new(fade)
    frame:update("tracked", true, true, false, 0.1)
    assert_eq(frame.pose_holds, true, "tracked holds the entry pose")
    frame:update("paused", true, true, false, 0.2)
    assert_eq(frame.pose_holds, false, "cycling to paused drops it")
end

print("== ADS frame OK ==")
