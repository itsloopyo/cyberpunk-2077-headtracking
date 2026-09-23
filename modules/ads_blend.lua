-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- ADS Blend
-- What aiming down sights does to the frame's head pose: nothing to the
-- rotation, and the lean eased out.
--
-- Head tracking carries straight on through the aim. The camera turns about
-- the eye, and the sights sit on a line through the eye, so however the head
-- turns the sights stay lined up on the weapon, which stays on the aim. A lean
-- is different: it moves the eye itself off that line, and the weapon does not
-- follow the camera's position. So the lean rides ads_fade.lua's scale - 1 at
-- the hip, 0 with the sights up - and returns when the weapon comes down.
--
-- Rotation and position are independently nil-able: rotation is interpolated
-- and arrives every frame, position arrives only on the frames a packet did. A
-- nil passes through as a nil rather than being scaled against a zero, which
-- would drag the applied lean toward centre on every frame without a packet.

local AdsBlend = {}

--- Apply the ADS transition to one frame's pose.
--- @param scale number ads_fade.lua's scale: 1 at the hip, 0 with the sights up
--- @param pose table {yaw, pitch, roll, x, y, z}; any field may be nil
--- @return table The pose to apply, same shape and same nils
function AdsBlend.blend(scale, pose)
    local out = { yaw = pose.yaw, pitch = pose.pitch, roll = pose.roll }
    if pose.x ~= nil then
        out.x = pose.x * scale
        out.y = pose.y * scale
        out.z = pose.z * scale
    end
    return out
end

return AdsBlend
