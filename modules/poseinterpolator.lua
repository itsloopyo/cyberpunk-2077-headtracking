-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Pose Interpolator
--
-- Bridges low-rate tracker samples (e.g. OpenTrack at 60 Hz) to the
-- render frame rate (e.g. 120 Hz). Without this, half of render frames
-- get no new sample and the camera holds still while the other half
-- jumps. The result is judder on high-refresh displays.
--
-- Algorithm: store a `from` pose and a `to` pose; on each frame advance
-- progress = dt / sampleInterval and output lerp(from, to, progress).
-- When a new raw sample arrives, capture the current interpolated
-- position as the new `from`, set the new sample as `to`, reset
-- progress. The sample interval is EMA-estimated so any tracker rate
-- works.
--
-- Extrapolation past progress=1.0 (up to 1.0 + MaxExtrapolationFraction)
-- maintains velocity continuity for the trailing half of each sample
-- period, eliminating velocity-drops-to-zero flat spots that read as
-- micro-stutters on high-refresh displays. Capped to avoid runaway
-- prediction on direction reversals, and expired on a wall clock so a
-- feed that stops entirely settles on the pose the tracker last reported
-- instead of parking on the prediction (see segmentPosition).
--
-- Yaw and roll interpolate along the shortest arc; pitch is a plain lerp
-- because it cannot wrap. See the per-axis note in update().
--
-- Port of cameraunlock-core/csharp/.../PoseInterpolator.cs.

local PoseInterpolator = {}
PoseInterpolator.__index = PoseInterpolator

local INTERVAL_BLEND          = 0.3       -- EMA weight for sample interval estimate
local DEFAULT_SAMPLE_INTERVAL = 1.0 / 30  -- seed estimate until real samples arrive
local MIN_SAMPLE_INTERVAL     = 0.001
local MAX_SAMPLE_INTERVAL     = 0.2

-- Seconds a sample may be late before the extrapolation starts expiring.
-- Sized to outlast an ordinary Wi-Fi loss burst (50-200 ms): a dropped packet
-- or two is still a live feed and must behave as it always did, because
-- retreating there would pull the camera BACKWARDS against a head that is
-- still turning, which reads far worse than the flat spot it replaces.
local EXTRAPOLATION_HOLD_SECONDS  = 0.25
-- Seconds over which a genuinely stalled feed converges back to the last
-- reported sample. Long enough that the correction is a drift, not a snap.
local EXTRAPOLATION_DECAY_SECONDS = 0.35

local math_fmod = math.fmod

--- Wrap an angle into -180..180. Port of cameraunlock-core
--- math::NormalizeAngle, including its fast path for the range head tracking
--- actually lives in.
--- @param angle number degrees
--- @return number degrees in -180..180
local function normalizeAngle(angle)
    if angle >= -180.0 and angle <= 180.0 then return angle end
    angle = math_fmod(angle, 360.0)
    if angle > 180.0 then
        angle = angle - 360.0
    elseif angle < -180.0 then
        angle = angle + 360.0
    end
    return angle
end

--- Shortest signed rotation from one angle to another, so a step across the
--- +-180 seam is the small one it looks like rather than its 360-degree
--- complement.
--- @param from number degrees
--- @param to number degrees
--- @return number degrees in -180..180
local function shortestAngleDelta(from, to)
    return normalizeAngle(to - from)
end

-- Exported so callers that subtract two tracker angles (init.lua's ADS entry
-- pose) use this seam-aware delta rather than a plain `a - b`, which turns a
-- 10-degree move across +-180 into its 350-degree complement.
PoseInterpolator.shortestAngleDelta = shortestAngleDelta

function PoseInterpolator.new()
    local self = setmetatable({}, PoseInterpolator)
    self.maxExtrapolationFraction = 0.5
    self:reset()
    return self
end

function PoseInterpolator:reset()
    self._fromYaw, self._fromPitch, self._fromRoll = 0, 0, 0
    self._toYaw,   self._toPitch,   self._toRoll   = 0, 0, 0
    self._lastSampleSeq            = nil       -- changes on fresh sample
    self._progress                 = 0
    self._sampleInterval           = DEFAULT_SAMPLE_INTERVAL
    self._timeSinceLastNewSample   = 0
    self._hasFirstSample           = false
    self._hasSecondSample          = false
end

--- Segment position to lerp at, for the given progress and however long the
--- next sample has already been outstanding.
---
--- Progress past 1.0 is extrapolation: a prediction, so it must not outlive
--- the sample it was predicting from by much. Clamping it and then HOLDING
--- parks the output at 1.5x the last reported pose for as long as samples stay
--- away - a tracker app streaming its last value while the face is lost, or a
--- head so still that consecutive samples are identical and never advance the
--- sequence number. A 25 degree head turn renders as 37.5 degrees and stays
--- there.
---
--- So the prediction expires, but on a WALL CLOCK rather than on progress:
--- progress is counted in estimated sample intervals, and that estimate only
--- moves when a sample arrives, so it is stale by construction in exactly the
--- stall case. Below the hold threshold this is the old behaviour unchanged;
--- past it the position eases (smoothstep, so no velocity step at either end)
--- to 1.0, the pose the tracker actually reported.
--- @param progress number Progress within the current segment
--- @return number Segment position to lerp at
function PoseInterpolator:segmentPosition(progress)
    if progress < 0 then return 0 end
    local maxPt = 1.0 + self.maxExtrapolationFraction
    local pt = progress > maxPt and maxPt or progress

    local late = self._timeSinceLastNewSample - EXTRAPOLATION_HOLD_SECONDS
    if late <= 0 then return pt end

    local u = late / EXTRAPOLATION_DECAY_SECONDS
    if u > 1 then u = 1 end
    local eased = u * u * (3.0 - 2.0 * u)
    return pt + (1.0 - pt) * eased
end

--- Advance one frame.
--- @param rawYaw number|nil   raw sample yaw (nil = no fresh sample this frame)
--- @param rawPitch number|nil
--- @param rawRoll number|nil
--- @param sampleSeq number|nil monotonically-increasing id; new value = fresh sample
--- @param deltaTime number    seconds since last update call
--- @return number|nil yaw, number|nil pitch, number|nil roll
function PoseInterpolator:update(rawYaw, rawPitch, rawRoll, sampleSeq, deltaTime)
    if deltaTime and deltaTime > 0 then
        self._timeSinceLastNewSample = self._timeSinceLastNewSample + deltaTime
    end

    -- A fresh sample is one with a different seq than the previous one.
    -- nil rawYaw means caller has nothing fresh - just continue interpolating.
    local isNewSample =
        rawYaw ~= nil and rawPitch ~= nil and rawRoll ~= nil
        and sampleSeq ~= nil and sampleSeq ~= self._lastSampleSeq

    if isNewSample then
        if not self._hasFirstSample then
            -- Park at the first sample. No interpolation yet.
            self._fromYaw, self._fromPitch, self._fromRoll = rawYaw, rawPitch, rawRoll
            self._toYaw,   self._toPitch,   self._toRoll   = rawYaw, rawPitch, rawRoll
            self._lastSampleSeq          = sampleSeq
            self._progress               = 1.0
            self._timeSinceLastNewSample = 0
            self._hasFirstSample         = true
            return rawYaw, rawPitch, rawRoll
        end

        -- Update sample interval EMA from observed gap. Ignore microscopic
        -- gaps (would push the estimate near zero).
        if self._timeSinceLastNewSample > MIN_SAMPLE_INTERVAL then
            if not self._hasSecondSample then
                self._sampleInterval = self._timeSinceLastNewSample
                self._hasSecondSample = true
            else
                self._sampleInterval = self._sampleInterval
                    + (self._timeSinceLastNewSample - self._sampleInterval) * INTERVAL_BLEND
            end
            if self._sampleInterval < MIN_SAMPLE_INTERVAL then self._sampleInterval = MIN_SAMPLE_INTERVAL end
            if self._sampleInterval > MAX_SAMPLE_INTERVAL then self._sampleInterval = MAX_SAMPLE_INTERVAL end
        end

        -- Capture current interpolated (possibly extrapolated) position
        -- as the new `from`. This preserves continuity through the
        -- segment transition, so it must be read BEFORE
        -- _timeSinceLastNewSample is reset below - after a stall the position
        -- on show is the decayed one, not the parked prediction.
        local t = self:segmentPosition(self._progress)
        self._fromYaw   = normalizeAngle(
            self._fromYaw + shortestAngleDelta(self._fromYaw, self._toYaw) * t)
        self._fromPitch = self._fromPitch + (self._toPitch - self._fromPitch) * t
        self._fromRoll  = normalizeAngle(
            self._fromRoll + shortestAngleDelta(self._fromRoll, self._toRoll) * t)

        -- New sample becomes the target.
        self._toYaw, self._toPitch, self._toRoll = rawYaw, rawPitch, rawRoll
        self._lastSampleSeq          = sampleSeq
        self._progress               = 0
        self._timeSinceLastNewSample = 0
    end

    if not self._hasFirstSample then
        return nil, nil, nil
    end

    -- Advance interpolation. Even when no new sample arrives, progress
    -- climbs each frame so the camera keeps moving toward the latest
    -- known target, avoiding the held-still judder pattern.
    self._progress = self._progress + (deltaTime or 0) / self._sampleInterval

    local pt = self:segmentPosition(self._progress)

    -- Yaw and roll traverse the SHORTEST arc. They arrive in -180..180 and can
    -- step across the seam, where a plain (to - from) turns a 1 degree move
    -- from 179.5 to -179.5 into a -359 degree sweep the long way round - the
    -- camera whips a full turn the wrong way and lands correct, so it reads as
    -- a violent glitch rather than a wrong result. Pitch is bounded to +-90 by
    -- the tracker's own asin and cannot wrap, so it stays a plain lerp: routing
    -- it through the same seam logic would be wrong, not merely redundant, once
    -- a from/to pair spanned more than 180 degrees.
    local outYaw   = normalizeAngle(
        self._fromYaw + shortestAngleDelta(self._fromYaw, self._toYaw) * pt)
    local outPitch = self._fromPitch + (self._toPitch - self._fromPitch) * pt
    local outRoll  = normalizeAngle(
        self._fromRoll + shortestAngleDelta(self._fromRoll, self._toRoll) * pt)
    return outYaw, outPitch, outRoll
end

return PoseInterpolator
