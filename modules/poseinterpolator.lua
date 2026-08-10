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
-- prediction on direction reversals.
--
-- Port of cameraunlock-core/csharp/.../PoseInterpolator.cs.

local PoseInterpolator = {}
PoseInterpolator.__index = PoseInterpolator

local INTERVAL_BLEND          = 0.3       -- EMA weight for sample interval estimate
local DEFAULT_SAMPLE_INTERVAL = 1.0 / 30  -- seed estimate until real samples arrive
local MIN_SAMPLE_INTERVAL     = 0.001
local MAX_SAMPLE_INTERVAL     = 0.2

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
        -- segment transition.
        local maxP = 1.0 + self.maxExtrapolationFraction
        local t = self._progress
        if t < 0 then t = 0 elseif t > maxP then t = maxP end
        self._fromYaw   = self._fromYaw   + (self._toYaw   - self._fromYaw)   * t
        self._fromPitch = self._fromPitch + (self._toPitch - self._fromPitch) * t
        self._fromRoll  = self._fromRoll  + (self._toRoll  - self._fromRoll)  * t

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

    local maxPt = 1.0 + self.maxExtrapolationFraction
    local pt = self._progress
    if pt < 0 then pt = 0 elseif pt > maxPt then pt = maxPt end

    local outYaw   = self._fromYaw   + (self._toYaw   - self._fromYaw)   * pt
    local outPitch = self._fromPitch + (self._toPitch - self._fromPitch) * pt
    local outRoll  = self._fromRoll  + (self._toRoll  - self._fromRoll)  * pt
    return outYaw, outPitch, outRoll
end

return PoseInterpolator
