-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Tests for modules/poseinterpolator.lua.
--
-- The interpolator is pure Lua with no CET dependencies, so it runs directly.
--
-- Two behaviours are pinned hardest here, both of them latent and silent.
--
-- Extrapolation expiry: the interpolator predicts up to half a sample period
-- past the newest sample to keep velocity continuous; that prediction used to
-- be clamped and then held forever, so a feed that stopped left the camera
-- parked at 1.5x the last reported pose - a 25 degree turn shown as 37.5
-- degrees until the tracker came back. A tracker streaming its last value
-- while the face is lost, and a head still enough that consecutive samples
-- never advance the sequence number, both look exactly like that to this
-- module.
--
-- Shortest-arc traversal: yaw and roll arrive wrapped into -180..180, so a
-- small move can step across the seam. Lerping those linearly sent the camera
-- the long way round - 175 to -175 is a 10 degree move that rendered as a 350
-- degree whip in the wrong direction, landing correct, so it reads as a
-- violent glitch rather than a wrong angle. Pitch cannot wrap and must stay a
-- plain lerp.

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

-- (8) Reset clears the stall clock along with everything else, so a scene change
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

-- ---------------------------------------------------------------------------
-- Shortest-arc traversal across the +-180 seam.
-- ---------------------------------------------------------------------------

-- Signed shortest rotation, written differently from the module's own version
-- (floor-mod rather than fmod) so the test is not just restating it.
local function arcDelta(from, to)
    local d = (to - from) % 360
    if d > 180 then d = d - 360 end
    return d
end

local QUARTER = 1.0 / 240.0

--- Drive a 60 Hz feed at 240 fps, the case this module exists for, so the
--- segment can be observed at quarter steps instead of only at its endpoints.
--- Two samples of `a` settle the interval estimate at exactly 1/60; the third
--- sample opens the a -> b segment and lands on progress 0.25.
--- @param a table {yaw, pitch, roll}
--- @param b table {yaw, pitch, roll}
--- @return table interpolator, number yaw, number pitch, number roll
local function segmentDriver(a, b)
    local pi = PoseInterpolator.new()
    pi:update(a[1], a[2], a[3], 1, QUARTER)
    for _ = 1, 3 do pi:update(nil, nil, nil, nil, QUARTER) end
    pi:update(a[1], a[2], a[3], 2, QUARTER)
    for _ = 1, 3 do pi:update(nil, nil, nil, nil, QUARTER) end
    local y, p, r = pi:update(b[1], b[2], b[3], 3, QUARTER)
    return pi, y, p, r
end

--- One more 240 fps frame with no fresh sample.
local function quarterStep(pi)
    return pi:update(nil, nil, nil, nil, QUARTER)
end

-- (9) 175 -> -175 is a 10 degree move. Every intermediate output must stay in
-- that 10 degree corridor around the seam; the linear lerp put them near 0.
do
    local pi, y = segmentDriver({ 175, 0, 175 }, { -175, 0, -175 })
    local outputs = { y }
    for _ = 1, 3 do outputs[#outputs + 1] = (quarterStep(pi)) end

    assert_near(outputs[1],  177.5, "quarter across the seam")
    assert_near(outputs[2],  180.0, "half way sits on the seam itself")
    assert_near(outputs[3], -177.5, "three quarters, wrapped past the seam")
    assert_near(outputs[4], -175.0, "segment ends on the reported sample")

    local travel = 0
    local prev = 175
    for _, out in ipairs(outputs) do
        assert_true(math.abs(out) >= 175 - EPS,
            string.format("stays in the 10 degree corridor (got %.3f)", out))
        assert_true(math.abs(out) <= 180 + EPS,
            string.format("output stays wrapped into -180..180 (got %.3f)", out))
        travel = travel + math.abs(arcDelta(prev, out))
        prev = out
    end
    assert_near(travel, 10, "total travel is the short way (10 deg, not 350)", 1e-3)
end

-- (10) The other direction across the seam, because a sign error in the delta
-- passes the forward case and fails this one.
do
    local pi, y = segmentDriver({ -175, 0, -175 }, { 175, 0, 175 })
    local outputs = { y }
    for _ = 1, 3 do outputs[#outputs + 1] = (quarterStep(pi)) end

    assert_near(outputs[1], -177.5, "quarter across the seam, reversed")
    assert_near(outputs[2], -180.0, "half way sits on the seam itself, reversed")
    assert_near(outputs[3],  177.5, "three quarters, wrapped past the seam, reversed")
    assert_near(outputs[4],  175.0, "segment ends on the reported sample, reversed")

    local travel = 0
    local prev = -175
    for _, out in ipairs(outputs) do
        assert_true(math.abs(out) >= 175 - EPS,
            string.format("stays in the corridor, reversed (got %.3f)", out))
        travel = travel + math.abs(arcDelta(prev, out))
        prev = out
    end
    assert_near(travel, 10, "total travel is the short way, reversed", 1e-3)
end

-- (11) Roll wraps too, and is a separate lerp with its own delta.
do
    local pi, _, _, r = segmentDriver({ 0, 0, 179 }, { 0, 0, -179 })
    local outputs = { r }
    for _ = 1, 3 do
        local _y, _p, roll = quarterStep(pi)
        outputs[#outputs + 1] = roll
    end

    assert_near(outputs[1],  179.5, "roll quarter across the seam")
    assert_near(outputs[2],  180.0, "roll half way")
    assert_near(outputs[3], -179.5, "roll three quarters")
    assert_near(outputs[4], -179.0, "roll ends on the reported sample")
end

-- (12) Pitch must NOT take a shortest arc. It is bounded to +-90 by the
-- tracker's own asin, so -80 to 80 is a real 160 degree sweep through zero,
-- and routing it through the seam logic would turn that into a 200 degree
-- move in the wrong direction.
do
    local pi, _, p = segmentDriver({ 0, -80, 0 }, { 0, 80, 0 })
    local outputs = { p }
    for _ = 1, 3 do
        local _y, pitch = quarterStep(pi)
        outputs[#outputs + 1] = pitch
    end

    assert_near(outputs[1], -40.0, "pitch quarter, straight through")
    assert_near(outputs[2],   0.0, "pitch half way passes through zero")
    assert_near(outputs[3],  40.0, "pitch three quarters, straight through")
    assert_near(outputs[4],  80.0, "pitch ends on the reported sample")
end

-- (13) Extrapolation past the seam stays wrapped, and the next segment picks up
-- from where the output actually was. The `from` capture wraps for the same
-- reason the output does: an unwrapped 190 stored as `from` would make the next
-- segment's delta the long way round.
do
    local pi = segmentDriver({ 175, 0, 0 }, { -175, 0, 0 })
    for _ = 1, 3 do quarterStep(pi) end            -- reach progress 1.0
    local at125 = quarterStep(pi)
    local at150 = quarterStep(pi)
    assert_near(at125, -172.5, "extrapolation past the seam, quarter over")
    assert_near(at150, -170.0, "extrapolation capped, half a period over")

    local resumed = pi:update(-165, 0, 0, 4, QUARTER)
    assert_true(math.abs(arcDelta(at150, resumed)) < 5,
        string.format("next segment continues from the wrapped position (got %.3f)", resumed))
    assert_true(math.abs(resumed) <= 180 + EPS, "resumed output stays wrapped")
end

print("== Pose interpolator OK ==")
