-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- ADS Frame
-- One frame's aim-down-sights decisions, as a pure step over the transition.
--
-- This exists because two shipped defects lived in exactly these four lines
-- when they were inline in init.lua, and neither was reachable from the gate
-- suite or the blend suite:
--
--   * `aiming` was conjoined with the gate verdict. In "paused" the fade is
--     what CLOSES that gate, so feeding the verdict back in made the fade start
--     raising the instant it finished lowering. The gate reopened a frame
--     later, the fade restarted at full scale, and the head pose snapped back
--     and re-eased several times a second for as long as the trigger was held.
--   * the entry pose was dropped the moment aiming ended, which makes the
--     relative pose equal to the absolute one, which makes the 250ms ride back
--     a blend of a value with itself. The view stepped by the whole entry
--     offset in one frame.
--
-- Both are ordering bugs in a decision that has no game in it at all, so it is
-- lifted out here and driven frame by frame in tests/ads_frame_test.lua.
--
-- The caller supplies the facts; this owns none of them:
--   mode              the ads_mode setting
--   aiming            the sights, as the GAME sees them (state:isAdsActive()),
--                     never the tracking gate's verdict
--   tracking_allowed  the gate verdict
--   reason_is_ads     the gate closed for ADS specifically, rather than for a
--                     menu, a load, a cinematic or the master toggle

local AdsFrame = {}
AdsFrame.__index = AdsFrame

--- @param fade table An ads_fade.lua instance
--- @return table AdsFrame instance
function AdsFrame.new(fade)
    local self = setmetatable({}, AdsFrame)
    self.fade = fade
    -- 1 at the hip, 0 with the sights up. What ads_blend.lua blends at.
    self.scale = 1.0
    -- Sights up in a mode that keeps tracking live. Gates the entry pose and
    -- the aim marker.
    self.tracked = false
    -- Whether ads_pose should hold its entry pose this frame. Outlives
    -- `tracked` by the length of the ride back.
    self.pose_holds = false
    -- The transition just reached or just left the sights-up end. The caller
    -- invalidates the gate's cache on this, so "paused" closes promptly rather
    -- than up to a cache TTL later.
    self.sights_up_changed = false
    return self
end

--- Advance one rendered frame.
--- @param mode string "paused", "marker" or "tracked"
--- @param aiming boolean The sights, independent of the gate
--- @param tracking_allowed boolean The gate verdict for this frame
--- @param reason_is_ads boolean The gate closed for ADS rather than anything else
--- @param now_s number os.clock()
--- @return number scale
function AdsFrame:update(mode, aiming, tracking_allowed, reason_is_ads, now_s)
    local was_sights_up = self.fade:isSightsUp()

    self.tracked = tracking_allowed and aiming and mode ~= "paused"
    self.scale = self.fade:update(aiming, now_s)
    self.sights_up_changed = self.fade:isSightsUp() ~= was_sights_up

    -- Held through the ride back as well as the aim, which is also what lets a
    -- re-aim inside the ramp resume the same aim rather than capturing a fresh
    -- entry pose mid-swing.
    self.pose_holds = mode ~= "paused"
        and (self.tracked or (tracking_allowed and self.scale < 1.0))

    -- The ADS block is the one suppression the transition must SURVIVE: it is
    -- the fade itself that closed that gate. Every other reason is a real
    -- suppression and the next aim should re-enter clean.
    if not tracking_allowed and not reason_is_ads then
        self.fade:reset()
        self.scale = 1.0
        self.tracked = false
        self.pose_holds = false
        -- Recomputed against the same baseline rather than carried over from
        -- above: the reset can itself have moved the fade off the sights-up end,
        -- and that is a change the gate has to be told about.
        self.sights_up_changed = self.fade:isSightsUp() ~= was_sights_up
    end

    return self.scale
end

return AdsFrame
