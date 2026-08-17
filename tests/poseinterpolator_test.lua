-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Tests for modules/poseinterpolator.lua.
--
-- The interpolator is pure Lua with no CET dependencies, so it runs directly.
--
-- The behaviour pinned hardest here is the expiry of the extrapolation. The
-- interpolator predicts up to half a sample period past the newest sample to
-- keep velocity continuous; that prediction used to be clamped and then held
-- forever, so a feed that stopped left the camera parked at 1.5x the last
-- reported pose - a 25 degree turn shown as 37.5 degrees until the tracker
-- came back. A tracker streaming its last value while the face is lost, and a
-- head still enough that consecutive samples never advance the sequence
-- number, both look exactly like that to this module.

local PoseInterpolator = assert(loadfile("modules/poseinterpolator.lua"))()

local EPS = 1e-4

local function assert_near(actual, expected, label, tol)
    tol = tol or EPS
    if type(actual) ~= "number" or math.abs(actual - expected) > tol then
        error(string.format("FAIL %s:\n  expected: %s (+-%s)\n  actual:   %s",
            label, tostring(expected), tostring(tol), tostring(actual)), 2)
    end
end

local function assert_true(cond, label)
    if not cond then
        error("FAIL " .. label, 2)
    end
end

local FRAME = 1.0 / 60.0

--- Feed two samples one frame apart so the interval estimate is a known 1/60
--- and the segment runs from `first` to `second`. The second update also
--- advances one frame, so the returned interpolator is already sitting exactly
--- on `second` with one frame of the next sample outstanding.
--- @return table interpolator
local function primed(first, second)
    local pi = PoseInterpolator.new()
    pi:update(first, first, first, 1, FRAME)
    pi:update(second, second, second, 2, FRAME)
    return pi
end

--- Advance n frames with no fresh sample.
local function coast(pi, frames)
    local yaw, pitch, roll
    for _ = 1, frames do
        yaw, pitch, roll = pi:update(nil, nil, nil, nil, FRAME)
    end
    return yaw, pitch, roll
end

print("== pose interpolator ==")

-- (1) A fresh sample every frame is plain interpolation: output lands on the
-- newest sample, no prediction involved.
do
    local pi = PoseInterpolator.new()
    local y = pi:update(0, 0, 0, 1, FRAME)
    assert_near(y, 0, "first sample parks at the sample")
    y = pi:update(10, 1, 2, 2, FRAME)
    assert_near(y, 10, "sample every frame tracks the newest sample")
end

-- (2) Extrapolation still runs, and still caps at 1.5x, while the feed is
-- merely late rather than stopped. This is the anti-judder behaviour and must
-- not have been traded away: a dropped packet or two has to keep predicting,
-- because retreating there would pull the camera backwards against a head
-- that is still turning.
do
    local pi = primed(0, 25)
    local y = coast(pi, 1)
    assert_near(y, 37.5, "one frame late: extrapolated to the 1.5x cap")

    -- primed() already leaves one frame outstanding, so 14 more reaches 0.25 s,
    -- the hold threshold, and nothing may have moved yet.
    local pi2 = primed(0, 25)
    local held = coast(pi2, 14)
    assert_near(held, 37.5, "held at the cap right up to the hold threshold")
end

-- (3) A feed that stops does NOT park on the prediction. Past the hold it
-- eases back to the pose the tracker actually reported.
do
    local pi = primed(0, 25)
    -- 0.25 s hold + 0.35 s decay = 0.6 s; 40 frames is 0.667 s.
    local y = coast(pi, 40)
    assert_near(y, 25, "stalled feed settles on the last reported pose")

    -- And it stays there rather than drifting past it.
    y = coast(pi, 120)
    assert_near(y, 25, "settled pose is stable, no drift past the sample")
end

-- (4) The decay is monotone and never overshoots the reported pose - the
-- smoothstep exists so the correction reads as a drift, not a snap.
do
    local pi = primed(0, 25)
    local prev = coast(pi, 14)
    assert_near(prev, 37.5, "decay starts from the capped prediction")

    local biggest_step = 0
    for _ = 1, 45 do
        local y = coast(pi, 1)
        assert_true(y <= prev + EPS, "decay is monotone (no rebound)")
        assert_true(y >= 25 - EPS, "decay never undershoots the reported pose")
        local step = math.abs(y - prev)
        if step > biggest_step then biggest_step = step end
        prev = y
    end
    -- 12.5 degrees over 0.35 s at 60 fps averages ~0.6 deg/frame; smoothstep
    -- peaks at 1.5x the average. A step anywhere near the full 12.5 would mean
    -- the ease had collapsed into a snap.
    assert_true(biggest_step < 1.5,
        string.format("no snap during decay (largest step %.3f deg)", biggest_step))
end

-- (5) A sample arriving after a stall continues from the decayed position, not
-- from the abandoned prediction. Continuing from 37.5 would step the camera
-- backwards the moment tracking resumed.
do
    local pi = primed(0, 25)
    coast(pi, 40)
    local y = pi:update(30, 30, 30, 3, FRAME)
    assert_true(y >= 25 - EPS and y <= 30 + EPS,
        string.format("resumed sample continues from the decayed pose (got %.3f)", y))
end

-- (6) Expiry is timed on the WALL CLOCK, not on progress. Progress is counted
-- in estimated sample intervals and that estimate only moves when a sample
-- arrives, so a slow tracker reaches the cap after few frames and a fast one
-- after many - but both must expire after the same 0.6 s of silence.
do
    local slow = PoseInterpolator.new()
    slow:update(0, 0, 0, 1, 0.1)
    slow:update(25, 25, 25, 2, 0.1)   -- 10 Hz feed
    local elapsed = 0
    while elapsed < 0.6 do
        slow:update(nil, nil, nil, nil, FRAME)
        elapsed = elapsed + FRAME
    end
    local y = slow:update(nil, nil, nil, nil, FRAME)
    assert_near(y, 25, "10 Hz feed expires on the same wall clock")
end

-- (7) segmentPosition directly, since it is the whole of the rule.
do
    local pi = PoseInterpolator.new()
    pi._timeSinceLastNewSample = 0
    assert_near(pi:segmentPosition(-5), 0, "negative progress clamps to 0")
    assert_near(pi:segmentPosition(0.4), 0.4, "in-segment progress passes through")
    assert_near(pi:segmentPosition(9), 1.5, "runaway progress caps at 1.5")

    pi._timeSinceLastNewSample = 0.25
    assert_near(pi:segmentPosition(9), 1.5, "at the hold threshold, still capped")

    pi._timeSinceLastNewSample = 0.25 + 0.175        -- half way through the decay
    assert_near(pi:segmentPosition(9), 1.25, "smoothstep is at its midpoint half way")

    pi._timeSinceLastNewSample = 10.0
    assert_near(pi:segmentPosition(9), 1.0, "fully expired sits on the sample")
    assert_near(pi:segmentPosition(0.4), 1.0,
        "expiry pulls an unfinished segment to the sample too")
end

-- (8) Reset clears the stall clock along with everything else, so a recenter
-- or scene transition cannot leave the next segment starting mid-decay.
do
    local pi = primed(0, 25)
    coast(pi, 40)
    pi:reset()
    local y = pi:update(nil, nil, nil, nil, FRAME)
    assert_true(y == nil, "no output until a sample arrives after reset")
    y = pi:update(7, 7, 7, 9, FRAME)
    assert_near(y, 7, "first sample after reset parks at the sample")
end

print("== Pose interpolator OK ==")
