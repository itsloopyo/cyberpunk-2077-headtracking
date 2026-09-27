-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Lean Clamp
-- Keeps a 6DOF lean from putting the eye inside the level. Port of
-- cameraunlock-core's cpp/include/cameraunlock/camera/lean_clamp.h, whose tests
-- (cpp/tests/lean_clamp_tests.cpp) tests/lean_clamp_test.lua runs case for case.
--
-- The policy lives here and the physics query stays with the caller: the query
-- is a function(start, direction, max_distance) returning
-- { queried = bool, blocked = bool, distance = number }. queried false means the
-- query could not run at all, which is not the same as a clear path.
--
-- Pure: no game, no clock. Vectors are plain {x, y, z} tables.

local LeanClamp = {}
LeanClamp.__index = LeanClamp

-- Below this the offset has no reliable direction to query along, and the lean
-- is too small to reach anything regardless.
local MINIMUM_LEAN = 1e-4
-- How close the release has to get, as a fraction of the lean, before the
-- allowance is called full.
local SETTLE_FRACTION = 1e-3

-- cameraunlock-core SmoothingUtils: speed = lerp(50, 0.1, smoothing).
local FRAME_INTERPOLATION_SPEED = 50.0
local MAX_SMOOTHING_SPEED = 0.1

local function smoothingFactor(smoothing, dt)
    local speed = FRAME_INTERPOLATION_SPEED
        - (FRAME_INTERPOLATION_SPEED - MAX_SMOOTHING_SPEED) * smoothing
    if speed > FRAME_INTERPOLATION_SPEED then speed = FRAME_INTERPOLATION_SPEED end
    if speed < MAX_SMOOTHING_SPEED then speed = MAX_SMOOTHING_SPEED end
    return 1.0 - math.exp(-speed * dt)
end

--- @param skin number How far off a surface to hold the eye, in metres. Must
---   exceed the camera's near clip distance, or the wall the eye is held off is
---   culled anyway.
--- @param release_smoothing number How quickly the allowance reopens, 0-1. 0.9
---   is a 200ms time constant. Tightening is never smoothed.
function LeanClamp.new(skin, release_smoothing)
    local self = setmetatable({}, LeanClamp)
    self.skin = skin
    self.release_smoothing = release_smoothing
    self.allowed = 0.0
    -- False means nothing is currently restricting the lean, which is not the
    -- same as an allowance of zero.
    self.has_allowance = false
    self.contact = false
    self.query_failed = false
    return self
end

--- The offset the world leaves room for, along the direction of `desired`.
--- query runs at most once per call and only when there is a lean to test.
---
--- Tightening is instant and releasing is damped. Easing INTO a smaller
--- allowance would leave the eye inside the wall for the duration of the ease,
--- which is the whole bug; easing back OUT stops the view popping when an
--- obstruction clears.
function LeanClamp:apply(eye, desired, dt, query)
    self.contact = false
    self.query_failed = false

    local mag = math.sqrt(desired.x * desired.x + desired.y * desired.y + desired.z * desired.z)
    if mag <= MINIMUM_LEAN then
        -- Dropping the allowance here rather than leaving it stale stops a wall
        -- the player has already backed away from rationing the next lean.
        self.has_allowance = false
        return { x = desired.x, y = desired.y, z = desired.z }
    end

    local dir = { x = desired.x / mag, y = desired.y / mag, z = desired.z / mag }
    local hit = query(eye, dir, mag + self.skin)

    if not hit.queried then
        -- No query, no clamp: the lean passes through, and the caller polls
        -- lastQueryFailed() and logs it, because a clamp that has quietly
        -- stopped clamping looks exactly like one that never engaged.
        self.query_failed = true
        self.has_allowance = false
        return { x = desired.x, y = desired.y, z = desired.z }
    end

    local room = hit.blocked and (hit.distance - self.skin) or mag
    local target = room
    if target < 0 then target = 0 elseif target > mag then target = mag end

    -- With no allowance carried in the frame starts at what the tracker asked
    -- for, rather than easing up from zero on every fresh lean.
    local allowed = self.has_allowance and self.allowed or mag
    if allowed > mag then allowed = mag end

    if target < allowed then
        allowed = target
        self.has_allowance = true
    elseif self.has_allowance then
        allowed = allowed + (target - allowed) * smoothingFactor(self.release_smoothing, dt)
        if mag - allowed <= mag * SETTLE_FRACTION then
            allowed = mag
            self.has_allowance = false
        end
    else
        -- Never restricted, so there is nothing to ease away from.
        allowed = mag
    end

    self.allowed = allowed
    self.contact = allowed < mag
    return { x = dir.x * allowed, y = dir.y * allowed, z = dir.z * allowed }
end

--- True when the last apply held the eye short of where the tracker asked.
function LeanClamp:inContact()
    return self.contact
end

--- True when the last apply could not run its query and passed the lean
--- through unclamped.
function LeanClamp:lastQueryFailed()
    return self.query_failed
end

--- Forget the current allowance. Call on any camera cut, so a previous room's
--- wall is not carried into the next one.
function LeanClamp:reset()
    self.allowed = 0.0
    self.has_allowance = false
    self.contact = false
    self.query_failed = false
end

return LeanClamp
