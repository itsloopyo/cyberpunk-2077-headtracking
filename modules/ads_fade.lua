-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- ADS Fade
-- The shape of the transition into and out of aiming down sights. Port of
-- cameraunlock-core's cpp/include/cameraunlock/ads/ads_fade.h; the two
-- durations are pinned to the core constants by tests/core_constants_test.lua.
--
-- The transition a mod rides to ease its positional lean out while the sights
-- are up and back in when they come down (ads_blend.lua). Rotation never rides
-- it: head tracking carries straight on through the aim.
--
-- This module owns the SHAPE of the transition and nothing else. It returns a
-- scale, 1 at the hip and 0 with the sights up.
--
-- Pure: no clock of its own, no game. now_s comes from the caller, which is
-- what lets the whole transition be driven frame by frame in a test.

local AdsFade = {}
AdsFade.__index = AdsFade

-- Seconds, because every clock in this port is os.clock(). The core spells
-- them in milliseconds; core_constants_test.lua converts and compares.
local LOWER_S = 0.150
local RAISE_S = 0.250

AdsFade.LOWER_S = LOWER_S
AdsFade.RAISE_S = RAISE_S

-- Below this the two ends of a transition are the same place and there is
-- nothing to travel.
local SETTLED = 1e-6

--- @return table AdsFade instance
function AdsFade.new()
    local self = setmetatable({}, AdsFade)
    self.state = "hip"   -- hip | lowering | aiming | raising
    self.start_s = 0
    -- The scale the current leg started from and is heading to. Held rather
    -- than assumed, because a leg can start anywhere: see update().
    self.from = 1.0
    self.target = 1.0
    self.duration_s = LOWER_S
    return self
end

-- Smoothstep, so the transition leaves and arrives at rest instead of starting
-- and stopping with a visible corner.
local function ease(elapsed, duration)
    local t = elapsed / duration
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return t * t * (3.0 - 2.0 * t)
end

-- Where the transition is right now, without advancing it.
local function currentScale(self, now_s)
    if self.state == "hip" then return 1.0 end
    if self.state == "aiming" then return 0.0 end
    local elapsed = now_s - self.start_s
    if elapsed >= self.duration_s then return self.target end
    return self.from + (self.target - self.from) * ease(elapsed, self.duration_s)
end

--- One rendered frame, before the lean is applied.
--- @param aiming boolean The ADS state for this frame, polled rather than latched
--- @param now_s number os.clock()
--- @return number scale 1 at the hip, 0 with the sights up
function AdsFade:update(aiming, now_s)
    local turn_down = aiming and (self.state == "hip" or self.state == "raising")
    local turn_up = (not aiming) and (self.state == "lowering" or self.state == "aiming")

    if turn_down or turn_up then
        -- A reversal starts from WHERE THE TRANSITION IS, not from the end it
        -- would have reached. Starting each leg at its own endpoint steps the
        -- lean by however far the interrupted leg had travelled, and the worst
        -- case is the most common input there is: a tap of the aim button
        -- releases a frame after it was pressed, so the lean is 99% applied and
        -- the next frame removes all of it. That is the jolt this module exists
        -- to remove, delivered by the module itself.
        local from = currentScale(self, now_s)
        local target = turn_down and 0.0 or 1.0
        local distance = math.abs(target - from)
        if distance < SETTLED then
            self.state = turn_down and "aiming" or "hip"
            return target
        end
        self.state = turn_down and "lowering" or "raising"
        self.from = from
        self.target = target
        -- Scaled by the distance left to travel, so an interrupted transition
        -- keeps the same RATE as a whole one rather than taking the full time
        -- to cover a fraction of the distance.
        self.duration_s = (turn_down and LOWER_S or RAISE_S) * distance
        self.start_s = now_s
    end

    local scale = currentScale(self, now_s)
    if (self.state == "lowering" or self.state == "raising")
            and (now_s - self.start_s) >= self.duration_s then
        self.state = (self.target == 0.0) and "aiming" or "hip"
    end
    return scale
end

--- Drop back to hip state. Call wherever tracking is suppressed - menu,
--- loading, cinematic, master toggle, tracker dropout - so the next aim starts
--- clean.
function AdsFade:reset()
    self.state = "hip"
    self.from = 1.0
    self.target = 1.0
end

return AdsFade
