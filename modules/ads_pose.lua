-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- ADS Entry Pose
-- Turns the absolute tracker pose into one relative to the pose the sights came
-- up on, for the ads_mode values that keep tracking live through the aim
-- ("marker" and "tracked"). "paused" never reaches here - the gate in state.lua
-- blocks first.
--
-- Relative means the entry frame is identity in yaw, pitch and position, so
-- raising the sights snaps the view onto the point the reticle was marking -
-- the same swing "paused" gets by standing tracking down - and head movement
-- from there still tracks. Lowering them returns to the absolute pose, which
-- swings back by the same angle. Roll passes through absolute throughout; see
-- the note in update().
--
-- Lives in its own module rather than inline in init.lua so the seam and
-- capture-timing rules below are covered by tests/ads_pose_test.lua. Both were
-- wrong in the first cut and neither is visible from a settings or gate test.

local PoseInterpolator = require("modules/poseinterpolator")
local angleDelta = PoseInterpolator.shortestAngleDelta

local AdsPose = {}
AdsPose.__index = AdsPose

--- @return table AdsPose instance
function AdsPose.new()
    local self = setmetatable({}, AdsPose)
    -- The pose the sights came up on, non-nil for exactly as long as they are
    -- up in a mode that keeps tracking live.
    self.entry = nil
    -- Latest position. Rotation is interpolated every frame, position is not,
    -- so a frame with no fresh packet still has to hand the entry capture a
    -- real translation rather than nil.
    self.last_x, self.last_y, self.last_z = 0, 0, 0
    return self
end

--- Drop the entry pose. Call this wherever tracking is suppressed, so the aim
--- re-enters cleanly rather than resuming against a pose from before the
--- suppression.
function AdsPose:reset()
    self.entry = nil
end

--- Are the sights up with an entry pose captured?
--- @return boolean
function AdsPose:isActive()
    return self.entry ~= nil
end

--- Map one frame's absolute pose to the pose to apply.
--- @param ads_tracked boolean Sights up in a mode that keeps tracking live
--- @param yaw number|nil Interpolated rotation; nil before the first sample
--- @param pitch number|nil
--- @param roll number|nil
--- @param x number|nil Position from a fresh packet; nil on frames without one
--- @param y number|nil
--- @param z number|nil
--- @return number|nil yaw, number|nil pitch, number|nil roll, number|nil x, number|nil y, number|nil z
function AdsPose:update(ads_tracked, yaw, pitch, roll, x, y, z)
    if x ~= nil then
        self.last_x, self.last_y, self.last_z = x, y, z
    end

    if not ads_tracked then
        self.entry = nil
    elseif not self.entry and yaw ~= nil then
        -- Gated on a live rotation, not merely on ads_tracked. The
        -- interpolator is reset on every suppressed frame and then returns nil
        -- until a fresh packet lands - roughly half the frames at a 60Hz
        -- tracker on a 120Hz display. Capturing then would freeze a pose from
        -- BEFORE the suppression and hold the whole aim at that offset. The
        -- path that hits it: aim down sights, open the map or press the ADS
        -- hotkey, move your head, come back with the sights still up.
        self.entry = {
            yaw = yaw, pitch = pitch,
            x = self.last_x, y = self.last_y, z = self.last_z,
        }
    end

    local e = self.entry
    if not e then
        return yaw, pitch, roll, x, y, z
    end

    -- Yaw goes through the seam-aware delta for the same reason the
    -- interpolator does: it arrives wrapped into -180..180, so a plain
    -- subtraction across the seam reads a 10-degree move as -350 and whips the
    -- view a full turn the wrong way. Pitch is bounded to +-90 by the tracker's
    -- own asin and cannot wrap, so it stays a plain difference.
    --
    -- Roll is deliberately NOT made relative. Yaw and pitch are the aim axes,
    -- and zeroing them is the whole point of the snap - it puts the view on the
    -- point the reticle was marking. Roll moves no aim point, it only tilts the
    -- horizon, so zeroing it on entry yanks a head tilt the player is actively
    -- holding back to level and then leans it in again as they move: two
    -- horizon jolts per aim, buying nothing.
    --
    -- The three rotation axes arrive as one triple, so one nil check covers
    -- them; position is independent and gets its own.
    local out_yaw, out_pitch, out_roll
    if yaw ~= nil then
        out_yaw   = angleDelta(e.yaw, yaw)
        out_pitch = pitch - e.pitch
        out_roll  = roll
    end

    if x == nil then
        return out_yaw, out_pitch, out_roll, nil, nil, nil
    end
    return out_yaw, out_pitch, out_roll, x - e.x, y - e.y, z - e.z
end

return AdsPose
