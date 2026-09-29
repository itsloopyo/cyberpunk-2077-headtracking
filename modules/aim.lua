-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Aim Compensation Module
--
-- When head tracking rotates the camera, bullets would normally land at the new
-- screen center. The C++ plugin hooks native aim functions and rotates by the INVERSE
-- of head tracking rotation, so bullets land at the original aim point.
--
-- This module stages the state the plugin needs; modules/udp.lua pushes it
-- through the plugin's HeadTrackingPushState script function every frame.

local Aim = {}
Aim.__index = Aim

local AimGeometry = require("modules/aim_geometry")

-- Diagnostic logger. Mirrors to CET console AND to a file next to the
-- mod so we can grep it without scrolling the console.
local dlog
do
    local ok, DebugLog = pcall(require, "modules/debuglog")
    if ok and DebugLog and DebugLog.write then
        dlog = DebugLog.write
    else
        dlog = function(msg) print(msg) end
    end
end

-- Scripted shot-direction discovery. When armed via Aim:armShotDiscovery
-- (DiagShotDiscovery console hook), every aim-direction override logs its
-- call rate + the incoming/outgoing forward so we can see, during sustained
-- automatic fire, WHICH scripted method the follow-up shots re-query (if any).
-- If none re-fires per shot, the follow-up direction is sourced in native code
-- and no scripted Override can catch it.
local _disco_until = 0
local _disco_counts = {}
local _disco_yaw = 0
local _disco_pitch = 0
local function discoArmed()
    return os.clock() < _disco_until
end
local function discoTap(method, fwd)
    if not discoArmed() then return end
    _disco_counts[method] = (_disco_counts[method] or 0) + 1
    local n = _disco_counts[method]
    if n <= 3 or (n % 20) == 0 then
        local fx, fy, fz = 0, 0, 0
        if fwd then fx, fy, fz = fwd.x or 0, fwd.y or 0, fwd.z or 0 end
        dlog(string.format(
            "[ShotDisco] %-42s call#%d in_fwd=(%.3f,%.3f,%.3f) yaw=%.1f pitch=%.1f",
            method, n, fx, fy, fz, _disco_yaw, _disco_pitch))
    end
end

-- Module-level state shared with Override callback
-- Must be outside the class for the Override closure to access it
-- "No head rotation is applied." Sent to the native side while tracking is
-- suppressed, because the aim hooks decide whether to peel from the quat they
-- were last handed.
local IDENTITY_QUAT = { i = 0, j = 0, k = 0, r = 1 }

local aim_state = {
    enabled = false,
    is_ads = false,
    ads_scale = 0.2,  -- 20% effect during ADS
    smooth_yaw = 0,
    smooth_pitch = 0,
    smooth_roll = 0,
    position_x = 0,
    position_y = 0,
    position_z = 0,
    aim_distance = 0,
    head_quat = { i = 0, j = 0, k = 0, r = 1 },
    override_registered = false,
    -- Tracking input. Set via Aim:setUdp() from init.lua so the
    udp = nil,
    -- OFF since the projectile restoration landed. Rounds now launch as
    -- projectiles and AimProviderHook peels the head rotation out of EVERY one,
    -- so this single-shot camera flick is a second compensation on top. It only
    -- fires on the first round of a trigger pull, which is exactly what that
    -- round double-peeled and landed mirrored on the far side of the reticle
    -- while the rest of the burst was correct.
    -- Experimental: while the fire button is HELD, hold cam+0xD0 clean every
    -- frame (after camera:apply) so the NATIVE auto-fire loop's per-shot reads
    -- see the mouse-only orientation, not just the first trigger-pull. Tests
    -- whether automatic follow-up shots read cam+0xD0 at all. Tradeoff: the
    -- view de-tracks (snaps mouse-forward) during sustained fire. PROVEN
    -- 2026-05-28: works for bullets but de-tracks the view unacceptably,
    -- because cam+0xD0 is the single shared view+aim slot. Default OFF; kept
    -- behind DiagHoldClean for reference. The acceptable fix is a sub-frame
    -- native bracket of the auto-fire's own cam+0xD0 read site.
}

-- Pre-cache math functions
local math_abs = math.abs

-- Hoisted pcall trampolines so the per-frame / per-shot paths don't allocate
-- a closure per call. Mirrors the same optimisation in modules/camera.lua.
local function _camGetLocalOrientation(cam)
    return cam:GetLocalOrientation()
end
local function _camSetLocalOrientation(cam, q)
    cam:SetLocalOrientation(q)
end


--- Below this many degrees on every axis the head is effectively centred, and
--- rotating the aim vector would only add float noise to a direction the game
--- is about to use for a raycast. Skipping the work also leaves the vanilla
--- vector object untouched on the overwhelmingly common centred-head frames.
local AIM_COMPENSATION_MIN_DEGREES = 0.1

--- Remove head rotation and translation from an engine-supplied forward vector,
--- so targeting previews and raycasts agree with the projectile aim point.
---
--- Returns the input UNCHANGED (same object) when tracking is off, the player
--- is in the vehicle chase camera, the vector is missing, or both rotation and
--- translation are centred - callers rely on that to hand the engine its
--- original vector back untouched.
---
--- The chase camera has nothing to compensate for. Head rotation reaches that
--- view through the native render-side injection and never enters camera
--- state, so the vector the engine just handed us already points where the
--- player is aiming; rotating it would be the error this function exists to
--- undo, applied backwards.
--- @param fwd table|nil Vector4 forward direction from the engine.
--- @return table|nil Compensated direction, or `fwd` as-is.
local function compensateForward(fwd)
    if not aim_state.enabled or not fwd then
        return fwd
    end

    local yaw = aim_state.smooth_yaw
    local pitch = aim_state.smooth_pitch
    local roll = aim_state.smooth_roll
    local rotation_active = math_abs(yaw) >= AIM_COMPENSATION_MIN_DEGREES
        or math_abs(pitch) >= AIM_COMPENSATION_MIN_DEGREES
        or math_abs(roll) >= AIM_COMPENSATION_MIN_DEGREES
    local position_active = aim_state.aim_distance > 0.001
        and math_abs(aim_state.position_x) + math_abs(aim_state.position_y)
            + math_abs(aim_state.position_z) > 0.00001
    if not rotation_active and not position_active then
        return fwd
    end

    local camera_system = Game.GetCameraSystem()
    local right = camera_system:GetActiveCameraRight()
    local forward = camera_system:GetActiveCameraForward()
    local up = camera_system:GetActiveCameraUp()

    return AimGeometry.compensateDirection(
        right, forward, up, fwd, aim_state.head_quat,
        aim_state.position_x, aim_state.position_y, aim_state.position_z,
        aim_state.aim_distance, position_active, fwd.w)
end

-- ---------------------------------------------------------------------------
-- PlayerAction classification
--
-- Pure helpers over the PlayerAction userdata the OnAction observer receives.
-- They close over nothing and touch no mod state, so they live here rather
-- than inside Aim:init() where they were originally written.
-- ---------------------------------------------------------------------------

--- Get a readable action name string from a PlayerAction userdata.
--- CET-version-tolerant. Tries `Game.NameToString`, then `:AsString()`,
--- then falls back to pulling the human label out of the `--[[ X --]]`
--- decorator CET injects into `tostring(CName)` so we don't just get
--- a hash-only representation that won't compare equal to "RangedAttack".
--- @param action userdata|nil PlayerAction from OnAction.
--- @return string|nil Human-readable action name, or nil if unavailable.
local function actionHumanName(action)
    if not action or not action.GetName then return nil end
    local n
    local ok, got = pcall(function() return action:GetName() end)
    if not ok or not got then return nil end
    n = got

    -- 1) Game.NameToString (most reliable on modern CET).
    local ok1, s1 = pcall(function() return Game.NameToString(n) end)
    if ok1 and type(s1) == "string" and #s1 > 0 and s1 ~= "None" then return s1 end

    -- 2) CName:AsString() callable form.
    local ok2, s2 = pcall(function() return n:AsString() end)
    if ok2 and type(s2) == "string" and #s2 > 0 and s2 ~= "None" then return s2 end

    -- 3) tostring() + `--[[ label --]]` decorator extraction.
    local raw = tostring(n)
    if type(raw) == "string" then
        local label = raw:match("%-%-%[%[%s*([%w_]+)%s*%-%-%]%]")
        if label then return label end
        return raw  -- last resort: raw ToCName{...} format
    end
    return nil
end

--- True when the action looks like a button PRESS. Defaults to true whenever
--- the action type can't be read, so an unreadable fire action still triggers
--- the decouple rather than being silently dropped.
--- @param action userdata|nil PlayerAction from OnAction.
--- @return boolean
local function isButtonPressedAction(action)
    if not action then return true end

    local ok, value = pcall(function()
        if action.GetType then return action:GetType() end
        return action.actionType
    end)
    if not ok or value == nil then return true end

    if type(value) == "number" then
        return value == 0
    end

    local okValue, numericValue = pcall(function() return value.value end)
    if okValue and type(numericValue) == "number" then
        return numericValue == 0
    end

    local text = tostring(value):lower()
    if text:find("button_pressed", 1, true) or text:find("pressed", 1, true) then
        return true
    end
    if text:find("released", 1, true) or text:find("hold_progress", 1, true) or
       text:find("hold_complete", 1, true) or text:find("repeat", 1, true) then
        return false
    end
    return true
end

--- True only on an explicit button-RELEASE action (used to clear the
--- firing-held latch so the hold-clean stops when fire stops). Distinct
--- from "not pressed" so hold-progress ticks don't prematurely clear it.
--- @param action userdata|nil PlayerAction from OnAction.
--- @return boolean
local function isButtonReleasedAction(action)
    if not action then return false end
    local ok, value = pcall(function()
        if action.GetType then return action:GetType() end
        return action.actionType
    end)
    if not ok or value == nil then return false end
    if type(value) == "number" then return value == 1 end
    local okv, num = pcall(function() return value.value end)
    if okv and type(num) == "number" then return num == 1 end
    return tostring(value):lower():find("released", 1, true) ~= nil
end

--- Create a new aim compensation instance
--- @param settings table Settings module instance
--- @param camera table Camera module instance
--- @return table Aim instance
function Aim.new(settings, camera)
    if not settings then
        error("[HeadTracking] Aim.new() requires a settings instance")
    end
    if not camera then
        error("[HeadTracking] Aim.new() requires a camera instance")
    end

    local self = setmetatable({}, Aim)
    self.settings = settings
    self.camera = camera

    return self
end

--- Initialize aim compensation (shared memory + legacy Override hooks)
--- Must be called once during mod initialization
--- @return boolean success
function Aim:init()
    if aim_state.override_registered then
        print("[HeadTracking:AIM] Override already registered")
        return true
    end

    print("[HeadTracking:AIM] Registering Override for TargetingSystem:GetCrosshairData")

    -- CET includes OUT params in the callback arguments, but they must be
    -- omitted when calling wrappedMethod. Their values are returned instead.
    Override("TargetingSystem", "GetCrosshairData",
        function(this, instigator, crosshairPosition, crosshairForward, wrappedMethod)
            local pos, fwd = wrappedMethod(instigator)
            discoTap("TargetingSystem:GetCrosshairData", fwd)
            return pos, compensateForward(fwd)
        end,
        2
    )

    print("[HeadTracking:AIM] GetCrosshairData Override registered")

    -- Also override GetBestComponentOnTargetObject which is called during targeting
    -- This function takes shootStartForward as input and may affect bullet trajectory
    print("[HeadTracking:AIM] Registering Override for TargetingSystem:GetBestComponentOnTargetObject")
    Override("TargetingSystem", "GetBestComponentOnTargetObject",
        function(this, shootStartPosition, shootStartForward, target, componentFilter, wrappedMethod)
            discoTap("TargetingSystem:GetBestComponentOnTargetObject", shootStartForward)
            return wrappedMethod(shootStartPosition,
                                 compensateForward(shootStartForward),
                                 target, componentFilter)
        end
    )
    print("[HeadTracking:AIM] GetBestComponentOnTargetObject Override registered")

    -- Also try overriding GetDefaultCrosshairData in case that's used for shooting
    print("[HeadTracking:AIM] Registering Override for TargetingSystem:GetDefaultCrosshairData")
    Override("TargetingSystem", "GetDefaultCrosshairData",
        function(this, instigator, crosshairPosition, crosshairForward, wrappedMethod)
            local pos, fwd = wrappedMethod(instigator)
            discoTap("TargetingSystem:GetDefaultCrosshairData", fwd)
            return pos, compensateForward(fwd)
        end,
        2
    )
    print("[HeadTracking:AIM] GetDefaultCrosshairData Override registered")

    -- FPPCameraComponent:GetForward and entCameraComponent:GetForward were
    -- overridden here to compensate the camera forward. Neither method exists
    -- on this build: CET logs "Function GetForward in class ... does not exist"
    -- and the Override is a no-op, but the surrounding pcall succeeds so the
    -- old code still printed "registered" and looked healthy. Removed rather
    -- than left claiming a compensation that never ran.

    aim_state.override_registered = true
    print("[HeadTracking:AIM] All Overrides and Observers registered successfully")
    return true
end

--- Update the head tracking rotation values
--- Called each frame from the main update loop.
--- @param yaw number Current smoothed yaw in degrees
--- @param pitch number Current smoothed pitch in degrees
--- @param roll number|nil Current smoothed roll in degrees
--- @param quat table|nil Head rotation quaternion {i,j,k,r} for the C++ hook
--- @param position_x number|nil Applied camera-local lateral offset in metres
--- @param position_y number|nil Applied camera-local longitudinal offset in metres
--- @param position_z number|nil Applied camera-local vertical offset in metres
--- @param aim_distance number|nil Distance to the clean aim hit in metres
function Aim:update(yaw, pitch, roll, quat, position_x, position_y, position_z, aim_distance)
    aim_state.smooth_yaw = yaw
    aim_state.smooth_pitch = pitch
    aim_state.smooth_roll = roll or 0
    aim_state.position_x = position_x or 0
    aim_state.position_y = position_y or 0
    aim_state.position_z = position_z or 0
    aim_state.aim_distance = aim_distance or 0
    _disco_yaw = yaw
    _disco_pitch = pitch
    if quat then
        aim_state.head_quat = quat
    end

    if aim_state.udp and aim_state.udp.setNativeState then
        aim_state.udp:setNativeState(yaw, pitch, aim_state.smooth_roll,
                                     aim_state.enabled, aim_state.is_ads,
                                     aim_state.head_quat,
                                     aim_state.position_x, aim_state.position_y,
                                     aim_state.position_z, aim_state.aim_distance)
    end
end

--- Enable or disable aim compensation. Called every frame from init.lua's
--- onUpdate, with `true` while tracking is allowed and `false` while blocked;
--- the next Aim:update stages it for the native push.
--- @param enabled boolean Whether aim compensation should be active
function Aim:setEnabled(enabled)
    aim_state.enabled = enabled
end

--- Stage "tracking is off, nothing is applied" for the next native push.
---
--- The suppressed path has to keep publishing rather than fall silent. The
--- native aim hooks decide whether to peel a head rotation off the player's
--- aim from the quat they were last handed, so a mod that stops talking
--- leaves them peeling a rotation that is no longer in the camera - which put
--- rounds fired down the sights exactly the head angle off target, mirrored
--- to the far side. Identity is the truthful value here: while suppressed we
--- apply no head rotation at all.
function Aim:publishSuppressedState()
    if not (aim_state.udp and aim_state.udp.setNativeState) then return end
    aim_state.udp:setNativeState(0, 0, 0, false, false, IDENTITY_QUAT)
end

--- Set ADS (Aiming Down Sights) state
--- @param is_ads boolean Whether currently aiming down sights
--- @param scale number|nil ADS effect multiplier (default 0.2 = 20%)
function Aim:setADS(is_ads, scale)
    aim_state.is_ads = is_ads or false
    if scale then
        aim_state.ads_scale = scale
    end
end





--- Periodically summarize discovery counts to the log. Shows firing
--- frequency per method so we can distinguish per-frame chatter from
--- per-shot fires.
function Aim:summarizeDiscovery()
    local now = os.clock()
    self._last_summary = self._last_summary or 0
    if now - self._last_summary < 3.0 then return end
    self._last_summary = now
    local t = aim_state._shoot_log_counts
    if not t then return end
    local parts = {}
    for k, v in pairs(t) do
        if v > 0 then table.insert(parts, k .. "=" .. v) end
    end
    if #parts == 0 then return end
    table.sort(parts)
    dlog("[HeadTracking:AIM] DISCOVERY counts: " .. table.concat(parts, " "))
end


--- Plug in the tracking input used for the native control channel.
function Aim:setUdp(udp)
    aim_state.udp = udp
end





--- Arm scripted shot-direction discovery for `seconds` (default 8). While
--- armed, every aim-direction Override logs its call rate + incoming forward.
--- Run it, then fire an automatic weapon (SMG) for the full window with the
--- head turned off-centre. Read HeadTracking-diag.log [ShotDisco] lines: a
--- method whose call count tracks the shot count is re-queried per shot (a
--- candidate to compensate); one that fires once-per-trigger-pull is bypassed
--- by the auto follow-ups (their direction is sourced in native code).
---   GetMod("HeadTracking").DiagShotDiscovery(8)
function Aim:armShotDiscovery(seconds)
    local s = (type(seconds) == "number" and seconds > 0) and seconds or 8
    -- DebugLog ships muted; enable it so [ShotDisco] lines land in the file.
    local ok, DebugLog = pcall(require, "modules/debuglog")
    if ok and DebugLog and DebugLog.setEnabled then DebugLog.setEnabled(true) end
    _disco_until = os.clock() + s
    _disco_counts = {}
    dlog(string.format("[ShotDisco] armed for ~%ds. Fire an SMG (full burst) with head turned now.", s))
end

--- Check if currently in ADS mode
--- @return boolean is_ads
function Aim:isADS()
    return aim_state.is_ads
end

--- Check if aim compensation is enabled
--- @return boolean enabled
function Aim:isEnabled()
    return aim_state.enabled
end

--- Get the current state for debugging
--- @return table state {enabled, is_ads, ads_scale, smooth_yaw, smooth_pitch, override_registered}
function Aim:getState()
    return {
        enabled = aim_state.enabled,
        is_ads = aim_state.is_ads,
        ads_scale = aim_state.ads_scale,
        smooth_yaw = aim_state.smooth_yaw,
        smooth_pitch = aim_state.smooth_pitch,
        override_registered = aim_state.override_registered,
    }
end

return Aim
