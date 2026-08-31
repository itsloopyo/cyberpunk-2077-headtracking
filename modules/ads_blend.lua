-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- ADS Blend
-- What the ADS fade does to the frame's head pose - and the one axis it leaves
-- alone. Port of cameraunlock-core's
-- cpp/include/cameraunlock/ads/ads_blend.h.
--
-- `scale` is ads_fade.lua's: 1 at the hip, 0 with the sights up, easing between
-- the two across the transition. `abs` is this frame's head pose at the engine
-- boundary; `rel` is the same pose measured from the frame the sights came up
-- on (ads_pose.lua).
--
--   "paused"             the pose fades to nothing and stays there, so the
--                        sight picture is the game's own.
--   "marker" / "tracked" it fades into the entry-relative pose, which is
--                        identity at the moment the sights come up - so the
--                        swing onto the aim is the same one "paused" makes, and
--                        head tracking carries on from there rather than from
--                        centre.
--
-- ROLL. In the TRACKED modes it is never made relative and never faded: a head
-- tilt moves neither the eye off the barrel nor the aim point off the middle of
-- the frame, so zeroing it would level a tilt the player is actively holding
-- and lean it back in as the weapon drops - two horizon jolts per aim, buying
-- nothing. ads_pose.lua already applies that rule, so relative roll IS the
-- absolute roll and the blend cannot move it.
--
-- "paused" DIVERGES from core's ads_blend.h here, and the reason is this mod's
-- gate rather than a different view of roll. Core's callers keep feeding the
-- camera a pose for the whole aim, so a held tilt simply stays held. This mod
-- hands the camera back: once the fade reaches zero the gate closes and
-- Camera:suspend() peels the WHOLE quaternion, roll included. Holding roll at
-- full through the fade therefore does not preserve it, it just moves the cut
-- to the end of the ramp and makes it a step instead of a ride. So in "paused"
-- roll rides the fade with everything else, and the tilt is gone smoothly by
-- the time the gate closes on it.
--
-- The rule that generalises is "roll must not jump", not "roll is never faded".
-- Which one you implement depends on whether the pose keeps flowing through the
-- aim.
--
-- Rotation and position are independently nil-able here for the same reason
-- they are in ads_pose.lua: rotation is interpolated and arrives every frame,
-- position arrives only on the frames a packet did. A nil on either side passes
-- through as a nil rather than being blended against a zero, which would drag
-- the applied value toward centre on every frame without a packet.

local AdsBlend = {}

--- Blend one frame's pose.
--- @param mode string "paused", "marker" or "tracked"
--- @param scale number 1 at the hip, 0 with the sights up
--- @param abs table {yaw, pitch, roll, x, y, z}; any field may be nil
--- @param rel table Same shape, measured from the entry frame
--- @return table The pose to apply, same shape and same nils
function AdsBlend.blend(mode, scale, abs, rel)
    local out = {}

    if mode == "paused" then
        if abs.yaw ~= nil then
            out.yaw = abs.yaw * scale
            out.pitch = abs.pitch * scale
            -- Faded, not held: see the ROLL note above for why this mod is the
            -- exception.
            out.roll = abs.roll * scale
        end
        -- The lean rides the same fade as the rotation rather than being cut at
        -- the edge: the sights sit on the muzzle line, so an eye offset from it
        -- moves the sight picture off the target, and cutting it in one frame is
        -- the jolt the fade exists to remove.
        if abs.x ~= nil then
            out.x = abs.x * scale
            out.y = abs.y * scale
            out.z = abs.z * scale
        end
        return out
    end

    -- Tracked: roll passes through untouched, which is what ads_pose.lua has
    -- already made it.
    out.roll = abs.roll

    local rest = 1.0 - scale
    if abs.yaw ~= nil and rel.yaw ~= nil then
        out.yaw = abs.yaw * scale + rel.yaw * rest
        out.pitch = abs.pitch * scale + rel.pitch * rest
    else
        out.yaw = rel.yaw
        out.pitch = rel.pitch
    end
    if abs.x ~= nil and rel.x ~= nil then
        out.x = abs.x * scale + rel.x * rest
        out.y = abs.y * scale + rel.y * rest
        out.z = abs.z * scale + rel.z * rest
    else
        out.x = rel.x
        out.y = rel.y
        out.z = rel.z
    end
    return out
end

return AdsBlend
