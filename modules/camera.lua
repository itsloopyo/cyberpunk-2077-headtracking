-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Camera Control Module
-- Applies head tracking rotation to the first-person camera
--
-- Features:
-- - 6DOF head tracking (pitch, yaw, roll, position)
-- - Per-axis sensitivity multipliers
-- - Per-axis rotation clamping
-- - Exponential smoothing with configurable factor
-- - Recenter calibration for neutral position offset
-- - Quaternion composition with game camera orientation
-- - Frame-rate independent smoothing using delta time

-- Shared file logger. Best-effort require: if the module isn't deployed
-- yet, dlog silently falls back to plain print so the mod still works.
local dlog
do
    local ok, DebugLog = pcall(require, "modules/debuglog")
    if ok and DebugLog and DebugLog.write then
        dlog = DebugLog.write
    else
        dlog = function(msg) print(msg) end
    end
end

local Camera = {}
Camera.__index = Camera

-- Count consecutive frames where the FPP camera component is nil while
-- tracking is supposed to be allowed. This DOES happen during legitimate
-- state transitions that our state detection doesn't catch (brief vehicle
-- enter/exit, scope swaps, scripted scenes, etc.). Log periodically so
-- persistent brokenness is visible, but never throw - stopping the tracking
-- loop for the rest of the session is worse than just skipping frames.
local consecutive_null_camera_frames = 0
local NULL_CAMERA_LOG_EVERY_FRAMES = 300  -- ~5s at 60fps

-- Pre-cache math functions for faster access (Lua optimization)
local math_exp = math.exp
local math_max = math.max

-- Hoisted pcall trampolines. Lua allocates a fresh closure for every
-- `pcall(function() ... end)` site, which is per-frame waste. Defining
-- these as module-scope functions and using `pcall(_fn, args...)` avoids
-- the closure allocation entirely without losing the error guard CET
-- userdata calls need.
local function _callQuatToEuler(q)
    return q:ToEulerAngles()
end
local function _callGetLocalOrientation(cam)
    return cam:GetLocalOrientation()
end
local function _callGetWorldOrientation(entity)
    return entity:GetWorldOrientation()
end
local function _callGetCameraSystem()
    return Game.GetCameraSystem()
end
local function _callGetActiveCameraWorldTransform(cameraSystem)
    return cameraSystem:GetActiveCameraWorldTransform()
end
local function _callGetOrientationProperty(transform)
    return transform.Orientation
end
local function _callGetOrientationMethod(transform)
    return transform:GetOrientation()
end
local function _callSetLocalOrientation(cam, q)
    cam:SetLocalOrientation(q)
end
local function _callSetLocalPosition(cam, v)
    cam:SetLocalPosition(v)
end

-- CameraUnlock baseline smoothing floor. Below this, high-refresh displays
-- show visible jitter - especially with wireless trackers. User-facing
-- smoothing_factor still reads 0.0 as "minimum"; the floor applies internally.
local BASELINE_SMOOTHING = 0.15

--- Frame-rate independent smoothing factor. Port of cameraunlock-core
--- SmoothingUtils.CalculateSmoothingFactor: speed = lerp(50, 0.1, smoothing),
--- alpha = 1 - exp(-speed * dt). At the 0.15 baseline floor and 60 fps this
--- gives ~0.5/frame, settling in ~100-150ms.
--- @param smoothing number Smoothing 0-1 (baseline floor already applied)
--- @param deltaTime number|nil Frame delta in seconds; defaults to 1/60
--- @return number Interpolation factor in (0, 1)
local function calculateSmoothingFactor(smoothing, deltaTime)
    local dt = deltaTime
    if not dt or dt <= 0 then dt = 1.0 / 60.0 end
    local speed = 50.0 + (0.1 - 50.0) * smoothing
    return 1.0 - math_exp(-speed * dt)
end

--- Clamp a value between min and max
--- @param value number The value to clamp
--- @param min_val number Minimum allowed value
--- @param max_val number Maximum allowed value
--- @return number Clamped value
local function clamp(value, min_val, max_val)
    if value < min_val then
        return min_val
    elseif value > max_val then
        return max_val
    end
    return value
end

--- Axial deadzone with smooth activation. Below |value| < d returns 0; above,
--- subtracts the deadzone in the input's direction so there is no jump at the
--- threshold. Matches cameraunlock-core's DeadzoneUtils.Apply.
local function applyDeadzone(value, deadzone)
    if not deadzone or deadzone <= 0 then return value end
    if value > deadzone then return value - deadzone end
    if value < -deadzone then return value + deadzone end
    return 0
end

-- Pre-cache math constants for NaN/Inf checks
local math_huge = math.huge

--- Check if a number is valid (not NaN or infinite)
--- @param n number The number to check
--- @return boolean true if valid
local function isValidNumber(n)
    return n == n and n ~= math_huge and n ~= -math_huge
end

--- Compute the inverse of a quaternion
--- For unit quaternions (which rotations are), inverse = conjugate
--- @param q Quaternion The quaternion to invert
--- @return Quaternion The inverse quaternion
local function quaternionInverse(q)
    -- Conjugate: negate i, j, k; keep r
    return Quaternion.new(-q.i, -q.j, -q.k, q.r)
end

--- Normalize a quaternion to unit length. quaternionInverse() returns the
--- conjugate, which only equals the true inverse for UNIT quaternions, and
--- cam:SetLocalOrientation expects a unit rotation. Any non-unit magnitude
--- (e.g. from chained multiplies) otherwise scales/compounds frame over frame.
--- @param q Quaternion
--- @return Quaternion unit-length copy (identity if degenerate)
local function quatNormalize(q)
    local mag = math.sqrt(q.i*q.i + q.j*q.j + q.k*q.k + q.r*q.r)
    if mag < 1e-6 then
        return Quaternion.new(0, 0, 0, 1)
    end
    local inv = 1.0 / mag
    return Quaternion.new(q.i * inv, q.j * inv, q.k * inv, q.r * inv)
end

--- Quaternion multiplication (Hamilton product). CET's Quaternion userdata
--- does NOT implement the `*` operator so we can't use q1 * q2 directly.
--- Every world-yaw composition attempt errored with "attempt to perform
--- arithmetic on a userdata value" until we replaced those with this call.
--- @param a Quaternion
--- @param b Quaternion
--- @return Quaternion a*b
local function quatMul(a, b)
    return Quaternion.new(
        a.r * b.i + a.i * b.r + a.j * b.k - a.k * b.j,  -- i
        a.r * b.j - a.i * b.k + a.j * b.r + a.k * b.i,  -- j
        a.r * b.k + a.i * b.j - a.j * b.i + a.k * b.r,  -- k
        a.r * b.r - a.i * b.i - a.j * b.j - a.k * b.k   -- r
    )
end

local function quatDelta(a, b)
    if not a or not b then return math_huge end
    local same =
        math.abs((a.i or 0) - (b.i or 0)) +
        math.abs((a.j or 0) - (b.j or 0)) +
        math.abs((a.k or 0) - (b.k or 0)) +
        math.abs((a.r or 0) - (b.r or 0))
    local negated =
        math.abs((a.i or 0) + (b.i or 0)) +
        math.abs((a.j or 0) + (b.j or 0)) +
        math.abs((a.k or 0) + (b.k or 0)) +
        math.abs((a.r or 0) + (b.r or 0))
    return math.min(same, negated)
end

-- Max quatDelta between what we wrote to cam.localOrientation last frame and
-- what we read back this frame for the engine to count as having KEPT our write
-- (incremental mutation). Above this, the engine has overwritten the orientation
-- with its own clean mouse value (camera-state events) and the head-peel must be
-- skipped - peeling last_head_quat off an already-clean value snaps the view off
-- by the head angle. ~0.08 L1 ≈ 9 degrees: clears smooth per-frame mouse look,
-- trips on a meaningful head turn's worth of divergence.
local PEEL_DIVERGENCE_THRESHOLD = 0.08

--- Create a new camera controller instance
--- @param settings table Settings module instance
--- @return table Camera instance
function Camera.new(settings)
    if not settings then
        error("[HeadTracking] Camera.new() requires a settings instance")
    end

    local self = setmetatable({}, Camera)
    self.settings = settings

    -- Smoothed rotation values (applied to camera)
    self.smooth_yaw = 0
    self.smooth_pitch = 0
    self.smooth_roll = 0

    -- Recenter offset (neutral position calibration)
    -- When user recenters, current tracker position becomes zero offset
    self.recenter_offset = {
        yaw = 0,
        pitch = 0,
        roll = 0
    }

    -- Last raw values from tracker (before any processing)
    -- Used for recenter functionality
    self.last_raw_yaw = 0
    self.last_raw_pitch = 0
    self.last_raw_roll = 0

    -- Timestamp for frame-rate independent smoothing
    self.last_update_time = nil

    -- Track last applied head quaternion to prevent accumulation
    -- Each frame: undo last offset, then apply new offset
    self.last_head_quat = nil

    -- Auto-recenter on first fresh packet (CameraUnlock rule 8).
    -- Counts stabilization frames while armed and fires recenter() once the
    -- tracker has had a few frames to stabilize. Armed at startup and on
    -- world load / session start only - never re-armed by a data gap, so a
    -- tracker that stops and resumes (face lost mid-session) keeps its center.
    self.stabilization_frames = 0
    self.pending_auto_recenter = true  -- true on startup so first-ever packets trigger recenter
    self.pending_initial_reset = true  -- one-shot hard reset on first frame cam is available

    -- Statistics for debugging
    self.stats = {
        update_count = 0,
        last_applied_yaw = 0,
        last_applied_pitch = 0,
        last_applied_roll = 0
    }

    -- Cached settings values to avoid repeated table lookups per frame
    -- These are refreshed via refreshSettingsCache() when settings change
    self.cached_settings = {
        sensitivity_yaw = 1.0,
        sensitivity_pitch = 1.0,
        sensitivity_roll = 1.0,
        smoothing_factor = 0.5,
        clamp_yaw = 120.0,
        clamp_pitch = 80.0,
        clamp_roll = 45.0,
        deadzone_yaw   = 0.5,
        deadzone_pitch = 0.5,
        deadzone_roll  = 1.0,
        yaw_mode = "world",
        decouple_diag_clean_cam = false,
        position_enabled = false,
        position_sens_x = 1.0,
        position_sens_y = 1.0,
        position_sens_z = 1.0,
        position_limit_x = 0.30,
        position_limit_y_up = 0.20,
        position_limit_y_down = 0.05,
        position_limit_z_fwd = 0.40,
        position_limit_z_back = 0.10,
        position_smoothing = 0.15,
    }
    -- Position pipeline state (separate from rotation smoothing).
    self.pos_center = { x = 0, y = 0, z = 0 }
    self.pos_center_set = false
    self.pos_smooth = { x = 0, y = 0, z = 0 }
    self.pos_local = { x = 0, y = 0, z = 0 }
    self.pos_applied = false   -- have we ever written a non-zero position?

    -- Initialize cache from settings
    self:refreshSettingsCache()

    -- Subscribe to settings changes for cache invalidation
    self._settings_unsubscribe = settings:observe("*", function(key, new_value)
        self:_onSettingChanged(key, new_value)
    end)

    return self
end

--- Refresh all cached settings values
--- Called on init and when settings change
function Camera:refreshSettingsCache()
    local s = self.settings
    self.cached_settings.sensitivity_yaw = s:get("sensitivity_yaw") or 1.0
    self.cached_settings.sensitivity_pitch = s:get("sensitivity_pitch") or 1.0
    self.cached_settings.sensitivity_roll = s:get("sensitivity_roll") or 1.0
    self.cached_settings.smoothing_factor = s:get("smoothing_factor") or 0.5
    self.cached_settings.clamp_yaw = s:get("clamp_yaw") or 120.0
    self.cached_settings.clamp_pitch = s:get("clamp_pitch") or 80.0
    self.cached_settings.clamp_roll = s:get("clamp_roll") or 45.0
    self.cached_settings.deadzone_yaw   = s:get("deadzone_yaw")   or 0.0
    self.cached_settings.deadzone_pitch = s:get("deadzone_pitch") or 0.0
    self.cached_settings.deadzone_roll  = s:get("deadzone_roll")  or 0.0
    self.cached_settings.yaw_mode = s:get("yaw_mode") or "world"
    local diag = s:get("decouple_diag_clean_cam")
    if diag == nil then diag = false end
    self.cached_settings.decouple_diag_clean_cam = diag
    local pe = s:get("position_enabled")
    if pe == nil then pe = false end
    self.cached_settings.position_enabled = pe
    self.cached_settings.position_sens_x = s:get("position_sens_x") or 1.0
    self.cached_settings.position_sens_y = s:get("position_sens_y") or 1.0
    self.cached_settings.position_sens_z = s:get("position_sens_z") or 1.0
    self.cached_settings.position_limit_x = s:get("position_limit_x") or 0.30
    self.cached_settings.position_limit_y_up = s:get("position_limit_y_up") or 0.20
    self.cached_settings.position_limit_y_down = s:get("position_limit_y_down") or 0.05
    self.cached_settings.position_limit_z_fwd = s:get("position_limit_z_fwd") or 0.40
    self.cached_settings.position_limit_z_back = s:get("position_limit_z_back") or 0.10
    self.cached_settings.position_smoothing = s:get("position_smoothing") or 0.15
end

--- Internal: Handle settings change notification
--- @param key string Setting key that changed
--- @param new_value any New value
function Camera:_onSettingChanged(key, new_value)
    -- Update only the changed setting in cache
    if self.cached_settings[key] ~= nil then
        self.cached_settings[key] = new_value
    end
end

--- Get the first-person camera component from the player
--- @return table|nil, table|nil FPP camera component and player, or nil if not available
local function getFPPCamera()
    local player = Game.GetPlayer()
    if not player then
        return nil, nil
    end

    local cam = player:GetFPPCameraComponent()
    return cam, player
end

-- World-mode (horizon-locked) head-rotation composition.
--
-- Head rotation is applied as a LOCAL offset on the FPP camera component:
-- final_local = clean * head, where `clean` is the camera's clean local
-- orientation. The engine then renders P * final_local, where P is the
-- player entity's world orientation. So the full clean view orientation is
-- W = P * clean, NOT `clean` alone.
--
-- For head YAW to swing the view about the WORLD-vertical axis - regardless
-- of how far the view has pitched up/down - the yaw must be applied in world
-- space on the OUTSIDE of the full view orientation W, while pitch/roll stay
-- view-local on the inside:
--
--     render = Qyaw_world * W * Qpitchroll_local
--
-- Since render = P * clean * head = W * head, the local offset we must
-- compose is:
--
--     head = W^-1 * Qyaw_world * W * Qpitchroll_local
--
-- The conjugation W^-1 * Qyaw_world * W re-bases the world-Z yaw axis into the
-- camera-local frame. Conjugating by the FULL world orientation (not just the
-- camera-local `clean`) is what makes this work: in Cyberpunk the mouse pitch
-- lives on the player entity's world orientation P, not on the camera's local
-- orientation, so a `clean`-only conjugation never saw the pitch and silently
-- collapsed to a plain world-Z yaw - identical to local-mode. Quaternion
-- conjugation is gimbal-free, so this stays well-defined even at +-90 degrees
-- of view pitch.
--
-- Hoisted to module scope so the default yaw_mode pays no per-frame closure
-- allocation.
local function composeWorldModeQuat(world_clean, smooth_roll, smooth_pitch, smooth_yaw)
    local Qy_world   = EulerAngles.new(0, 0, smooth_yaw):ToQuat()
    local Qpr_local  = EulerAngles.new(smooth_roll, smooth_pitch, 0):ToQuat()
    local world_inv  = quaternionInverse(world_clean)
    local Qy_local   = quatMul(quatMul(world_inv, Qy_world), world_clean)
    return quatMul(Qy_local, Qpr_local)
end

--- Best-effort conversion of a Quaternion to its "pitch/yaw/roll" in degrees
--- for human-readable debug output. Uses CET's built-in ToEulerAngles() if
--- available; otherwise returns nil fields so the log just omits those values.
--- @param q Quaternion
--- @return number|nil pitch
--- @return number|nil yaw
--- @return number|nil roll
local function quatToPYR(q)
    if not q or not q.ToEulerAngles then return nil, nil, nil end
    local ok, e = pcall(_callQuatToEuler, q)
    if not ok or not e then return nil, nil, nil end
    return e.pitch, e.yaw, e.roll
end

-- Why the last lookup failed. World yaw mode degrades to a pitch-free
-- reference when this returns nil, which makes it behave exactly like local
-- mode, so the reason is recorded and reported once instead of being swallowed.
local world_orient_fail_reason = nil

local function getActiveCameraForward()
    local okCS, cs = pcall(_callGetCameraSystem)
    if not okCS or not cs then return nil end
    local ok, f = pcall(function() return cs:GetActiveCameraForward() end)
    if ok and f then return f end
    return nil
end

local function getActiveCameraWorldOrientation()
    local okCS, cs = pcall(_callGetCameraSystem)
    if not okCS or not cs then
        world_orient_fail_reason = "Game.GetCameraSystem() failed or returned nil"
        return nil
    end

    local okWT, wt = pcall(_callGetActiveCameraWorldTransform, cs)
    if not okWT or not wt then
        world_orient_fail_reason = "cameraSystem:GetActiveCameraWorldTransform() failed or returned nil"
        return nil
    end

    local okProp, q = pcall(_callGetOrientationProperty, wt)
    if (not okProp or not q) then
        local okMethod, qm = pcall(_callGetOrientationMethod, wt)
        if okMethod then q = qm end
        if not q then
            world_orient_fail_reason =
                "WorldTransform: neither the .Orientation property nor :GetOrientation() returned a value"
            return nil
        end
    end

    if q and isValidNumber(q.i) and isValidNumber(q.j)
         and isValidNumber(q.k) and isValidNumber(q.r) then
        world_orient_fail_reason = nil
        return quatNormalize(q)
    end
    world_orient_fail_reason = "orientation quaternion had non-finite components"
    return nil
end

--- Apply head tracking rotation to the camera.
--- Processes raw tracker data through: offset -> sensitivity -> clamp -> smooth -> apply.
---
--- @param yaw number Raw yaw rotation in degrees from tracker
--- @param pitch number Raw pitch rotation in degrees from tracker
--- @param roll number Raw roll rotation in degrees from tracker
--- @param deltaTime number|nil Optional delta time for smoothing (defaults to os.clock delta)
--- @param combatState table|nil Currently unused.
--- @param skip_cam_write boolean|nil When true, run the processing pipeline
---   and stash the computed head_quat but do NOT write to cam:SetLocalOrientation.
---   Set to true by init.lua when aim:nativeCameraHookActive() - the C++ view-matrix
---   hook is handling render-side injection and we must leave cam.transform clean
---   (otherwise the game sees a double-rotated camera).
function Camera:apply(yaw, pitch, roll, deltaTime, combatState, skip_cam_write)
    -- Validate input values
    if not isValidNumber(yaw) or not isValidNumber(pitch) or not isValidNumber(roll) then
        return
    end

    -- Store raw values for recenter functionality
    self.last_raw_yaw = yaw
    self.last_raw_pitch = pitch
    self.last_raw_roll = roll

    -- Deferred recenter capture. recenter() runs in the per-frame hook BEFORE
    -- the UDP poll + interpolator update, so snapshotting last_raw_* there
    -- captures the PREVIOUS frame's interpolator output. Tracker jitter +
    -- extrapolation between frames meant adj_* was non-zero after a press
    -- and the user had to mash Home several times for the residual to
    -- converge. Capture here against the current frame's input instead -
    -- single press zeroes adj_* exactly.
    if self._pending_recenter_capture then
        self.recenter_offset.yaw = yaw
        self.recenter_offset.pitch = pitch
        self.recenter_offset.roll = roll
        self._pending_recenter_capture = false
    end

    -- Get camera component and player
    local cam, player = getFPPCamera()
    if not cam or not player then
        consecutive_null_camera_frames = consecutive_null_camera_frames + 1
        if consecutive_null_camera_frames == 1 then
            dlog("[HeadTracking] Camera component NOT AVAILABLE (GetFPPCameraComponent returned nil) - skipping frame")
        elseif (consecutive_null_camera_frames % NULL_CAMERA_LOG_EVERY_FRAMES) == 0 then
            dlog(string.format(
                "[HeadTracking] Camera component still nil after %d frames (~%.1fs). Tracking skipped this frame; will retry each frame.",
                consecutive_null_camera_frames, consecutive_null_camera_frames / 60.0))
        end
        return
    end

    if consecutive_null_camera_frames > 0 then
        dlog("[HeadTracking] Camera component AVAILABLE again after " .. consecutive_null_camera_frames .. " null frame(s)")
        consecutive_null_camera_frames = 0
    end

    -- Step 1: Apply recenter offset
    -- After recentering, the stored offset is subtracted so that position becomes neutral
    -- Invert yaw so looking left turns camera left (natural mapping)
    -- Invert roll so tilting head left tilts camera left
    local adj_yaw = -(yaw - self.recenter_offset.yaw)
    local adj_pitch = pitch - self.recenter_offset.pitch
    local adj_roll = -(roll - self.recenter_offset.roll)

    -- Step 2: Apply per-axis deadzone (smooth activation). Eats tracker noise
    -- so a still head doesn't accumulate sub-degree drift through the
    -- smoothing+composition chain. Applied BEFORE sensitivity to match the
    -- cameraunlock-core pipeline (center -> deadzone -> sensitivity -> ...).
    local cache = self.cached_settings
    adj_yaw   = applyDeadzone(adj_yaw,   cache.deadzone_yaw)
    adj_pitch = applyDeadzone(adj_pitch, cache.deadzone_pitch)
    adj_roll  = applyDeadzone(adj_roll,  cache.deadzone_roll)

    -- Step 3: Apply sensitivity multipliers from cached settings (avoid table lookups)
    adj_yaw = adj_yaw * cache.sensitivity_yaw
    adj_pitch = adj_pitch * cache.sensitivity_pitch
    adj_roll = adj_roll * cache.sensitivity_roll

    -- Step 3: Clamp to the user-configured per-axis limits.
    --
    -- Historically this step also applied "Soft Look" - tighter clamps and
    -- a 20% scale-down when a weapon was drawn or ADS - to stop head rotation
    -- from dragging the aim around. Now that aim is decoupled from view via
    -- the TargetingSystem Override, there's nothing to fight; head yaw/pitch
    -- no longer influence where bullets go, so the combat-based clamps just
    -- feel like an arbitrary leash. Dropped entirely.
    adj_yaw   = clamp(adj_yaw,   -cache.clamp_yaw,   cache.clamp_yaw)
    adj_pitch = clamp(adj_pitch, -cache.clamp_pitch, cache.clamp_pitch)
    adj_roll  = clamp(adj_roll,  -cache.clamp_roll,  cache.clamp_roll)

    -- Step 4: Apply smoothing (exponential moving average)
    -- smoothing_factor: 0.0 = no smoothing (instant), 1.0 = maximum smoothing (slow)
    -- Baseline floor (CameraUnlock rule) enforced here, not in settings, so the
    -- user-visible default stays 0.0.
    local smoothing = math_max(cache.smoothing_factor, BASELINE_SMOOTHING)
    local factor = calculateSmoothingFactor(smoothing, deltaTime)

    -- Apply exponential moving average
    self.smooth_yaw = self.smooth_yaw + (adj_yaw - self.smooth_yaw) * factor
    self.smooth_pitch = self.smooth_pitch + (adj_pitch - self.smooth_pitch) * factor
    self.smooth_roll = self.smooth_roll + (adj_roll - self.smooth_roll) * factor

    -- Validate smoothed values
    if not isValidNumber(self.smooth_yaw) then self.smooth_yaw = 0 end
    if not isValidNumber(self.smooth_pitch) then self.smooth_pitch = 0 end
    if not isValidNumber(self.smooth_roll) then self.smooth_roll = 0 end

    -- Read the clean (mouse-only) base orientation. World-mode re-bases the
    -- head-yaw axis onto this orientation (see composeWorldModeQuat).
    --
    -- The FPP camera's local orientation carries the mouse PITCH - body yaw
    -- lives on the parent player entity, so composing on top of it leaves
    -- body-frame aim/movement untouched and keeps mouse look working.
    --
    -- IMPORTANT (2026-05-20, confirmed via drift-diag): Cyberpunk's controller
    -- fully OVERWRITES cam.localOrientation each frame with its clean mouse
    -- orientation - it does NOT retain last frame's head rotation. (The prior
    -- code assumed incremental mutation and "peeled off" last_head_quat via
    -- current * conj(last_head); since conj != inverse for non-unit quats that
    -- both scaled the magnitude AND, because the read is already clean,
    -- re-injected an inverse head rotation that cancelled the head rotation we
    -- re-applied - net zero view movement.) So the read IS the clean base; use
    -- it directly and normalize defensively.
    --
    -- Caveat: anything that reads cam.forward (camera frame) still sees head
    -- rotation. Full aim-decoupling for native bullet-spawn paths needs the
    -- C++ pre/post camera hook - see native/RE_NOTES.md.
    local current_quat
    do
        local ok, got = pcall(_callGetLocalOrientation, cam)
        if ok and got and isValidNumber(got.i) and isValidNumber(got.j)
                       and isValidNumber(got.k) and isValidNumber(got.r) then
            current_quat = quatNormalize(got)
        else
            current_quat = Quaternion.new(0, 0, 0, 1)  -- identity fallback
        end
    end

    -- Peel last frame's head rotation back off to recover the clean base.
    -- Cyberpunk's FPP controller mutates cam.localOrientation INCREMENTALLY
    -- (it keeps last frame's value and applies the mouse delta on top), so the
    -- read still carries the head rotation we wrote last frame. Subtract it:
    -- current = clean_curr * head_prev  =>  clean_curr = current * head_prev^-1.
    -- Without this the head rotation compounds every frame into a wild spin.
    -- This REQUIRES unit quaternions: quaternionInverse() is the conjugate,
    -- which equals the true inverse only for unit length. (The earlier
    -- regression wrote non-unit quats, so the engine rejected them - hence the
    -- drift-diag showing read==clean - and the conjugate-as-inverse peel was
    -- wrong. Both are fixed now that current_quat/head_quat are normalized.)
    -- Did the engine KEEP our last write (incremental mutation) vs OVERWRITE it
    -- with its own clean orientation (camera-state events: ADS in/out, weapon
    -- swap, vehicle enter/exit, cutscene/dialogue blends, FPP resets)? Peeling
    -- last_head_quat off an already-overwritten (clean) value injects a spurious
    -- inverse head rotation and snaps the view/gun off by the head angle - the
    -- intermittent "points the wrong way". One signal drives every peel below
    -- (local and world): world = parent * local, so an overwrite of local is an
    -- overwrite of world too.
    local engine_kept_our_write = self.last_head_quat and self._last_written_final_quat
        and quatDelta(current_quat, self._last_written_final_quat) <= PEEL_DIVERGENCE_THRESHOLD

    local clean_quat
    if self._pending_recenter_unroll then
        -- Hard recenter (Home key panic-button): strip roll from the current
        -- cam.localOrientation and discard every peel-state cache. Covers the
        -- "stuck rolled" symptom where clean_quat itself has accumulated roll
        -- (engine mid-session reset, or progressively-corrupted writes through
        -- a stale last_head_quat). Mouse yaw/pitch are preserved so we don't
        -- yank the player's aim.
        --
        -- Peel last_head_quat FIRST so we get the TRUE mouse-only base before
        -- stripping roll. current_quat carries last frame's head rotation
        -- incrementally (cyberpunk persists our writes); reading p/y straight
        -- off it preserves the old head pitch+yaw and bakes it permanently
        -- into the new "clean" base, leaving the view stuck off-center after
        -- recenter. With the peel, the recenter genuinely returns to
        -- mouse-only orientation in one press.
        local base_quat = current_quat
        if self.last_head_quat then
            base_quat = quatNormalize(quatMul(current_quat, quaternionInverse(self.last_head_quat)))
        end
        local p, y, _r = quatToPYR(base_quat)
        if p and y then
            clean_quat = quatNormalize(EulerAngles.new(p, y, 0):ToQuat())
        else
            clean_quat = Quaternion.new(0, 0, 0, 1)
        end
        self.last_head_quat = nil
        self.last_clean_local_quat = nil
        self._last_written_final_quat = nil
        self._pending_recenter_unroll = false
        self._skip_head_peel_once = false
    elseif self._skip_head_peel_once then
        clean_quat = engine_kept_our_write
            and quatNormalize(quatMul(current_quat, quaternionInverse(self.last_head_quat)))
            or current_quat
        self._skip_head_peel_once = false
    elseif self.last_head_quat then
        clean_quat = engine_kept_our_write
            and quatNormalize(quatMul(current_quat, quaternionInverse(self.last_head_quat)))
            or current_quat
    else
        clean_quat = current_quat
    end

    -- Step 5: Build the head rotation quaternion.
    --
    --   "local" - legacy: EulerAngles(roll, pitch, yaw) as a single local
    --             offset. Head yaw rotates around the camera-local up axis,
    --             which tilts with mouse pitch, so sweeps are not
    --             horizon-locked. Ships as the A/B-test counterpart.
    --
    --   "world" - horizon-locked (default). Head yaw rotates about world
    --             vertical regardless of mouse pitch by re-basing the yaw
    --             axis onto clean_quat. See composeWorldModeQuat.
    --
    -- Any other yaw_mode value is treated as "world".
    local head_quat
    local yaw_mode = self.cached_settings.yaw_mode
    if yaw_mode == "local" then
        head_quat = EulerAngles.new(self.smooth_roll, self.smooth_pitch, self.smooth_yaw):ToQuat()
    else
        local okP, pw = pcall(_callGetWorldOrientation, player)
        local parent_world = nil
        if okP and pw and isValidNumber(pw.i) and isValidNumber(pw.j)
                     and isValidNumber(pw.k) and isValidNumber(pw.r) then
            parent_world = quatNormalize(pw)
        end

        -- Prefer the camera-system world orientation as the "clean world"
        -- reference: on this build, mouse pitch lives downstream of
        -- cam.localOrientation, so deriving clean_world from parent_world *
        -- clean_local loses it (clean_local is pitch-free), and the yaw axis
        -- collapses back onto local-Z, making world and local modes look
        -- identical. The active camera world transform DOES carry mouse pitch;
        -- peel our last-applied head quat (right-multiplied into the local
        -- orientation, so right-peeled in world space too since world = parent
        -- * local) to recover the true clean world orientation.
        local cam_world_now = getActiveCameraWorldOrientation()
        local world_is_true = cam_world_now ~= nil
        local clean_world = nil
        if cam_world_now then
            if engine_kept_our_write then
                clean_world = quatNormalize(quatMul(cam_world_now, quaternionInverse(self.last_head_quat)))
            else
                clean_world = cam_world_now
            end
        elseif parent_world then
            -- Fallback (no camera-system transform available): synthesize from
            -- parent_world * clean_local. Loses mouse pitch on this build, which
            -- collapses the yaw axis back onto local-Z and makes world mode
            -- indistinguishable from local. Say so once rather than leaving the
            -- user toggling a switch that does nothing.
            clean_world = quatNormalize(quatMul(parent_world, clean_quat))
            if not self._world_degraded_logged then
                self._world_degraded_logged = true
                -- print, not dlog: DebugLog is disabled by default, and a mode
                -- that silently does nothing is exactly what must not be quiet.
                print("[HeadTracking] WORLD yaw mode DEGRADED to camera-local: " ..
                      tostring(world_orient_fail_reason or "camera-system orientation unavailable") ..
                      " - horizon lock inactive")
            end
        end

        -- clean_world is the synthetic parent*clean and carries no mouse pitch,
        -- because getActiveCameraWorldOrientation() never returns anything:
        -- GetActiveCameraWorldTransform takes an out-parameter and we call it
        -- with none, so it errors every frame. Fixing that call is the tidier
        -- route, but the forward vector is a simpler reference and is already
        -- proven, so take the view pitch from there.
        --
        -- Only the PITCH of the clean view orientation matters here: world yaw
        -- is a rotation about world Z and so is the yaw part of W, and rotations
        -- about the same axis commute, so the yaw cancels out of
        -- W^-1 * Qyaw * W entirely. That reduces the reference we need from a
        -- full orientation to one scalar.
        local view_pitch = nil
        local fwd = getActiveCameraForward()
        if fwd then
            local okz, z = pcall(function() return fwd.z end)
            if okz and isValidNumber(z) then
                if z > 1.0 then z = 1.0 elseif z < -1.0 then z = -1.0 end
                local rendered_pitch = math.deg(math.asin(z))
                -- fwd includes the head rotation we applied last frame; peel it
                -- so the reference is the CLEAN (mouse-only) view pitch.
                local hp = 0
                if self.last_head_quat then
                    local p = quatToPYR(self.last_head_quat)
                    if isValidNumber(p) then hp = p end
                end
                view_pitch = rendered_pitch - hp
            end
        end

        if view_pitch or clean_world then
            if not self._world_active_logged then
                self._world_active_logged = true
                print(string.format(
                    "[HeadTracking] WORLD yaw mode ACTIVE (pitch reference: %s)",
                    view_pitch and "camera forward vector"
                        or (world_is_true and "camera-system orientation" or "NONE - degraded")))
            end

            -- head must satisfy  W * head = Qyaw_world * W * Qpitchroll_local,
            -- so head = W^-1 * Qyaw_world * W * Qpitchroll_local: the SAME W on
            -- both sides of the yaw.
            --
            -- Conjugating with parent_world * clean_quat on the left while using
            -- clean_world on the right (what this did before) mixes a pitch-free
            -- orientation with a pitched one. A conjugation with mismatched
            -- factors does not move the yaw axis onto world vertical at all, so
            -- head yaw stayed on the camera-local axis and world mode was
            -- indistinguishable from local no matter how the lookup went.
            -- Pitch-only reference when we have it: W reduces to Qpitch, and
            -- composeWorldModeQuat conjugates the world yaw by exactly that.
            local W = clean_world
            if view_pitch then
                W = EulerAngles.new(0, view_pitch, 0):ToQuat()
            end
            head_quat = composeWorldModeQuat(W,
                self.smooth_roll, self.smooth_pitch, self.smooth_yaw)
        else
            -- Neither the camera system nor the player gave a world orientation,
            -- so the only reference left is the clean LOCAL one. Conjugating by
            -- that puts the yaw axis back on camera-local, which is local mode
            -- in all but name. Report it once rather than pretending.
            if not self._world_degraded_logged then
                self._world_degraded_logged = true
                print("[HeadTracking] WORLD yaw mode DEGRADED (no world orientation available): " ..
                      tostring(world_orient_fail_reason or "player world orientation unavailable") ..
                      " - horizon lock inactive")
            end
            head_quat = composeWorldModeQuat(clean_quat,
                self.smooth_roll, self.smooth_pitch, self.smooth_yaw)
        end
    end
    head_quat = quatNormalize(head_quat)

    -- DIAGNOSTIC (yaw-mode A/B): when probeYawMode() armed a deadline, log the
    -- raw orientations and BOTH candidate head quats so we can see whether
    -- world and local actually diverge and where the view pitch lives. Throttled.
    if self._yaw_diag_until and os.clock() < self._yaw_diag_until then
        self._yaw_diag_counter = (self._yaw_diag_counter or 0) + 1
        if (self._yaw_diag_counter % 15) == 0 then
            local cp, cy = quatToPYR(clean_quat)
            local okP2, pw2 = pcall(_callGetWorldOrientation, player)
            local pp, py = nil, nil
            if okP2 and pw2 and isValidNumber(pw2.i) then
                pp, py = quatToPYR(quatNormalize(pw2))
            end
            -- Where does the mouse VIEW pitch actually live? C and P never
            -- carry it, so query the camera SYSTEM's active-camera world
            -- transform - that is downstream of the component orientations and
            -- should hold the mouse pitch. Probe several shapes and dump raw
            -- values so we can lock onto whatever this build exposes.
            local csInfo = "noCamSys"
            local okCS, cs = pcall(_callGetCameraSystem)
            if okCS and cs then
                local okWT, wt = pcall(_callGetActiveCameraWorldTransform, cs)
                if okWT and wt then
                    local q = getActiveCameraWorldOrientation()
                    if q then
                        local qp, qy, qr = quatToPYR(q)
                        csInfo = string.format("camSysWT(p=%s y=%s r=%s)",
                            tostring(qp and string.format("%.1f",qp)),
                            tostring(qy and string.format("%.1f",qy)),
                            tostring(qr and string.format("%.1f",qr)))
                    else
                        csInfo = "WT.no-orientation"
                    end
                else
                    local okFwd, cfwd = pcall(function() return cs:GetActiveCameraForward() end)
                    if okFwd and cfwd and isValidNumber(cfwd.z) then
                        local z = cfwd.z; if z>1 then z=1 elseif z<-1 then z=-1 end
                        csInfo = string.format("camSysFwd(pitch=%.1f x=%.2f y=%.2f z=%.2f)",
                            math.deg(math.asin(z)), cfwd.x or -9, cfwd.y or -9, cfwd.z or -9)
                    else
                        csInfo = "noWT-noFwd"
                    end
                end
            end
            local f = io.open("yaw-diag.log", "a")
            if f then
                f:write(string.format(
                    "[%s] head(y=%.1f p=%.1f r=%.1f) | C(p=%s y=%s) P(p=%s y=%s) | %s\n",
                    os.date("%H:%M:%S"), self.smooth_yaw, self.smooth_pitch, self.smooth_roll,
                    tostring(cp and string.format("%.1f",cp)), tostring(cy and string.format("%.1f",cy)),
                    tostring(pp and string.format("%.1f",pp)), tostring(py and string.format("%.1f",py)),
                    csInfo))
                f:close()
            end
        end
    end

    -- Step 6: Validate the head-rotation quaternion.
    -- Any NaN/Inf component can crash the game engine when fed to
    -- SetLocalOrientation (observed on world-mode transitions). Guard
    -- every field before we hand anything over.
    local hi, hj, hk, hr = head_quat.i, head_quat.j, head_quat.k, head_quat.r
    local h_mag2 = hi*hi + hj*hj + hk*hk + hr*hr
    local headQuatOk =
        isValidNumber(hi) and isValidNumber(hj) and
        isValidNumber(hk) and isValidNumber(hr) and
        -- Unit-ish. A raw magnitude between ~0.9 and ~1.1 is fine; catastrophic
        -- values (0 length or enormous) indicate the math went sideways.
        h_mag2 > 0.25 and h_mag2 < 4.0

    if not headQuatOk then
        return
    end

    -- Always stash the computed head quaternion so aim.lua can forward it
    -- to the C++ view-matrix hook via shared memory - whether or not we
    -- end up writing to the camera below. Preserve the previous value so
    -- getRenderedYPR() can midpoint-average the two for the reticle.
    self._prev_head_quat = self._computed_head_quat
    self._computed_head_quat = head_quat

    -- Native hook handoff: the C++ view-matrix hook is injecting head
    -- rotation at render time, so we must NOT also write it into
    -- cam.localOrientation (that would double-rotate the render AND
    -- re-couple aim to head). Restore the clean base we already recovered
    -- and bail out before the normal write path.
    if skip_cam_write then
        if self.last_head_quat then
            pcall(_callSetLocalOrientation, cam, clean_quat)
            self.last_head_quat = nil
            self.last_clean_local_quat = nil
        end
        return
    end

    -- Step 7: Compose head rotation ON TOP of the clean base: final =
    -- clean_quat * head_quat. In world mode head_quat already carries the
    -- conjugation that puts its yaw on the world axis, so this single
    -- multiply yields Qyaw_world * clean * Qpitchroll_local.

    -- DIAGNOSTIC: when decouple_diag_clean_cam is on, write CLEAN (mouse-only)
    -- quat to cam.localOrientation. The point is to observe which engine
    -- systems read cam+0xD0 - whatever still follows the head after this
    -- flip is reading from somewhere else; whatever now follows the mouse
    -- (interaction prompts, hitscan target, click-flick direction, ...)
    -- IS reading cam+0xD0. View tracking will visibly break - that is
    -- expected and is what makes the diagnostic legible.
    local write_head_rotation = not self.cached_settings.decouple_diag_clean_cam
    local final_quat = write_head_rotation and quatNormalize(quatMul(clean_quat, head_quat)) or clean_quat

    local fi, fj, fk, fr = final_quat.i, final_quat.j, final_quat.k, final_quat.r
    local f_mag2 = fi*fi + fj*fj + fk*fk + fr*fr
    local finalQuatOk =
        isValidNumber(fi) and isValidNumber(fj) and
        isValidNumber(fk) and isValidNumber(fr) and
        f_mag2 > 0.25 and f_mag2 < 4.0

    if finalQuatOk then
        local ok, err = pcall(_callSetLocalOrientation, cam, final_quat)
        if not ok then
            dlog("[HeadTracking] SetLocalOrientation failed: " .. tostring(err))
            return
        end
        -- Remember what we applied so next frame can undo it; and stash
        -- the clean base for aim decoupling to consult. In diag-clean-cam
        -- mode we wrote clean (no head rotation), so the "applied head
        -- rotation" was effectively identity - record nil so the next
        -- frame's undo path is a no-op rather than peeling off a head
        -- quat that we never actually applied.
        self.last_head_quat = write_head_rotation and head_quat or nil
        self.last_clean_local_quat = clean_quat
        self._last_written_final_quat = { i = fi, j = fj, k = fk, r = fr }
    end


    -- Update statistics
    self.stats.update_count = self.stats.update_count + 1
    self.stats.last_applied_yaw = self.smooth_yaw
    self.stats.last_applied_pitch = self.smooth_pitch
    self.stats.last_applied_roll = self.smooth_roll
end

--- Stabilization frames required after arming before we auto-recenter. The
--- first few packets from a freshly connected tracker are often garbage
--- (initialization, warmup).
local AUTO_RECENTER_STABILIZATION_FRAMES = 5

--- One-shot startup reset: forces cam.localOrientation to identity and
--- clears the undo-chain caches the first frame the FPP cam is available.
--- Independent of tracker packets so the camera lands in a clean state
--- even if OpenTrack isn't running yet at game launch.
function Camera:tryInitialReset()
    if not self.pending_initial_reset then return end
    local cam = getFPPCamera()
    if not cam then return end
    pcall(_callSetLocalOrientation, cam, Quaternion.new(0, 0, 0, 1))
    self.last_head_quat = nil
    self.last_clean_local_quat = nil
    self._computed_head_quat = nil
    self._prev_head_quat = nil
    self.pos_center_set = false
    self.pos_smooth.x = 0
    self.pos_smooth.y = 0
    self.pos_smooth.z = 0
    self.pos_local.x = 0
    self.pos_local.y = 0
    self.pos_local.z = 0
    self.pos_applied = false
    self.pending_initial_reset = false
    print("[HeadTracking] Initial reset applied (cam.localOrientation -> identity)")
end

--- Note that a fresh packet was just applied. Ticks the stabilization counter
--- and fires auto-recenter on the Nth fresh packet after arming.
function Camera:noteFreshPacket()
    if self.pending_auto_recenter then
        self.stabilization_frames = self.stabilization_frames + 1
        if self.stabilization_frames >= AUTO_RECENTER_STABILIZATION_FRAMES then
            self:recenter()
            self.pending_auto_recenter = false
            self.stabilization_frames = 0
            print("[HeadTracking] Auto-recentered after tracker connection")
        end
    end
end

--- Arm a fresh auto-recenter. The next batch of fresh packets (after the
--- stabilization window) will be captured as the new neutral pose. Called on
--- world load / session start so every spawn re-centers on the player's
--- current head pose, instead of relying on the one-shot first-connection
--- recenter which can fire stale or be missed.
function Camera:armAutoRecenter()
    self.pending_auto_recenter = true
    self.stabilization_frames = 0
end

--- Store current head position as the neutral/center position
--- After recentering, looking straight ahead = no camera offset
--- Call this when user presses the recenter hotkey (F9)
function Camera:recenter()
    -- Defer the offset capture into apply(). recenter() runs in the per-frame
    -- hook BEFORE udp:poll + pose_interp:update, so self.last_raw_* still
    -- holds the previous frame's interpolator output. Capturing here meant
    -- the offset was always one frame stale (and worse with extrapolation +
    -- tracker jitter), so a single press left a residual the user had to
    -- mash Home to converge. Flag instead, and let apply() snapshot the
    -- current frame's actual input as the neutral.
    self._pending_recenter_capture = true

    -- Reset smoothed values so the new neutral resolves to ~zero head rotation.
    self.smooth_yaw = 0
    self.smooth_pitch = 0
    self.smooth_roll = 0

    -- Home is the panic-button: signal apply() to strip roll from the current
    -- cam.localOrientation and drop every peel-state cache. Fixes the "stuck
    -- rolled, Home does nothing" symptom that the plain peel can't recover
    -- from once clean_quat itself has accumulated roll. apply() runs in the
    -- same frame as us (init.lua onUpdate calls recenter() then apply()), so
    -- the single-write invariant is preserved (apply does the only write).
    self._pending_recenter_unroll = true
    self._skip_head_peel_once = false

    -- Also re-capture the position zero point so 6DOF returns to neutral
    -- as part of the same hotkey action.
    self.pos_center_set = false
    self.pos_smooth.x = 0
    self.pos_smooth.y = 0
    self.pos_smooth.z = 0
    self.pos_local.x = 0
    self.pos_local.y = 0
    self.pos_local.z = 0
    self.pos_applied = false

    print("[HeadTracking] Recenter armed (offset captured next apply)")
end

--- Reset all rotation offsets and smoothed values
--- Camera returns to game's default orientation
--- Call this when tracking is disabled or state changes
function Camera:reset()
    self.smooth_yaw = 0
    self.smooth_pitch = 0
    self.smooth_roll = 0
    self.pending_auto_recenter = true
    self.stabilization_frames = 0
    self.last_clean_local_quat = nil

    -- If we baked a head rotation into the camera, peel it off now so
    -- toggling tracking off actually returns to the clean pose. Cyberpunk
    -- does not fully overwrite cam.localOrientation each frame, so our
    -- last write persists until we undo it. Forcing identity (the previous
    -- behaviour) was the wrong escape hatch: it wiped mouse pitch along
    -- with head rotation.
    if self.last_head_quat then
        local cam = getFPPCamera()
        if cam then
            local ok, current = pcall(_callGetLocalOrientation, cam)
            if ok and current and isValidNumber(current.i) and isValidNumber(current.j)
                              and isValidNumber(current.k) and isValidNumber(current.r) then
                local clean = quatMul(current, quaternionInverse(self.last_head_quat))
                pcall(_callSetLocalOrientation, cam, clean)
            end
        end
        self.last_head_quat = nil
    end
end

function Camera:prepareYawModeSwitch()
    -- Clear yaw-mode-dependent intermediates so the new mode recomposes from
    -- scratch. Do NOT touch last_head_quat / _last_written_final_quat / set
    -- _skip_head_peel_once: last_head_quat is the exact quaternion we
    -- right-multiplied into cam.localOrientation last frame, so apply()'s
    -- normal peel undoes it cleanly regardless of which yaw mode produced it.
    -- Skipping the peel here caused each PageDown press to bake the current
    -- head pose permanently into the "clean" base (drift accumulated, and
    -- recenter then locked onto the drifted orientation).
    self.last_clean_local_quat = nil
    self._computed_head_quat = nil
    self._prev_head_quat = nil
end

--- Get the current recenter offset values
--- @return table {yaw, pitch, roll} offset values in degrees
function Camera:getRecenterOffset()
    return {
        yaw = self.recenter_offset.yaw,
        pitch = self.recenter_offset.pitch,
        roll = self.recenter_offset.roll
    }
end

--- Set the recenter offset directly (for advanced use cases)
--- @param yaw number Yaw offset in degrees
--- @param pitch number Pitch offset in degrees
--- @param roll number Roll offset in degrees
function Camera:setRecenterOffset(yaw, pitch, roll)
    if isValidNumber(yaw) then self.recenter_offset.yaw = yaw end
    if isValidNumber(pitch) then self.recenter_offset.pitch = pitch end
    if isValidNumber(roll) then self.recenter_offset.roll = roll end
end

--- Recenter the position pipeline. Captures the current raw input as the
--- new zero point. Called explicitly and also on first packet.
function Camera:recenterPosition(rx, ry, rz)
    self.pos_center.x = rx or 0
    self.pos_center.y = ry or 0
    self.pos_center.z = rz or 0
    self.pos_center_set = true
    self.pos_smooth.x = 0
    self.pos_smooth.y = 0
    self.pos_smooth.z = 0
    self.pos_local.x = 0
    self.pos_local.y = 0
    self.pos_local.z = 0
end

--- Apply 6DOF head translation to the FPP camera.
--- Inputs are raw OpenTrack cm values (lateral, vertical, longitudinal).
--- Pipeline: recenter -> per-axis sensitivity -> exponential smoothing ->
---           cm to m -> axis remap -> asymmetric clamp -> SetLocalPosition.
--- Cyberpunk local cam frame (smoke-test confirmed): +Z is up; we map
---   OT y (vertical, +up)   -> cam Z
---   OT x (lateral, +right) -> cam X
---   OT z (longitudinal, +fwd) -> cam Y
function Camera:applyPosition(rx, ry, rz, deltaTime)
    local c = self.cached_settings
    if not c.position_enabled then
        if self.pos_applied then
            local cam = getFPPCamera()
            if cam then pcall(_callSetLocalPosition, cam, Vector4.new(0, 0, 0, 1.0)) end
            self.pos_applied = false
        end
        self.pos_local.x = 0
        self.pos_local.y = 0
        self.pos_local.z = 0
        return
    end
    if not isValidNumber(rx) or not isValidNumber(ry) or not isValidNumber(rz) then
        return
    end

    if not self.pos_center_set then
        self:recenterPosition(rx, ry, rz)
        return
    end

    local cam = getFPPCamera()
    if not cam then return end

    -- 1) recenter, 2) sensitivity (per OT axis, before remap so user-facing
    --    knobs match OT conventions)
    local dx = (rx - self.pos_center.x) * c.position_sens_x
    local dy = (ry - self.pos_center.y) * c.position_sens_y
    local dz = (rz - self.pos_center.z) * c.position_sens_z

    -- 3) cm -> m
    dx, dy, dz = dx * 0.01, dy * 0.01, dz * 0.01

    -- 4) exponential smoothing, frame-rate independent.
    local s = math_max(c.position_smoothing, BASELINE_SMOOTHING)
    local alpha = calculateSmoothingFactor(s, deltaTime)
    self.pos_smooth.x = self.pos_smooth.x + (dx - self.pos_smooth.x) * alpha
    self.pos_smooth.y = self.pos_smooth.y + (dy - self.pos_smooth.y) * alpha
    self.pos_smooth.z = self.pos_smooth.z + (dz - self.pos_smooth.z) * alpha

    -- 5) axis remap (OT -> Cyberpunk local cam). X and Y (cam-frame
    --    lateral/longitudinal) are inverted so the camera tracks head
    --    motion in the expected direction (leaning right moves view
    --    right; leaning forward moves view forward).
    local cam_x = -self.pos_smooth.x                      -- lateral (inverted)
    local cam_y = -self.pos_smooth.z                      -- forward (inverted)
    local cam_z =  self.pos_smooth.y                      -- vertical

    -- 6) asymmetric clamp
    local lx = c.position_limit_x
    local ly_up, ly_dn = c.position_limit_y_up, c.position_limit_y_down
    local lz_fwd, lz_back = c.position_limit_z_fwd, c.position_limit_z_back
    if cam_x >  lx then cam_x =  lx elseif cam_x < -lx then cam_x = -lx end
    if cam_z >  ly_up then cam_z =  ly_up elseif cam_z < -ly_dn then cam_z = -ly_dn end
    if cam_y >  lz_fwd then cam_y =  lz_fwd elseif cam_y < -lz_back then cam_y = -lz_back end

    if not (isValidNumber(cam_x) and isValidNumber(cam_y) and isValidNumber(cam_z)) then
        return
    end

    pcall(_callSetLocalPosition, cam, Vector4.new(cam_x, cam_y, cam_z, 1.0))
    self.pos_local.x = cam_x
    self.pos_local.y = cam_y
    self.pos_local.z = cam_z
    self.pos_applied = true
end

function Camera:getAppliedPosition()
    return self.pos_local.x, self.pos_local.y, self.pos_local.z
end

--- Arm the yaw-mode A/B diagnostic for `seconds` (default 6). While armed,
--- apply() appends decomposed orientations and both candidate head quats to
--- yaw-diag.log so we can confirm whether world/local diverge and where the
--- view pitch lives. Move the mouse to pitch the view up/down and pan your
--- head while this runs.
--- @param seconds number|nil
function Camera:probeYawMode(seconds)
    local dur = tonumber(seconds) or 6
    self._yaw_diag_until = os.clock() + dur
    self._yaw_diag_counter = 0
    print(string.format("[HeadTracking:DIAG] yaw-mode probe armed for %.0fs -> yaw-diag.log", dur))
end

function Camera:diagYawBasis()
    local cam, player = getFPPCamera()
    if not cam or not player then
        print("[HeadTracking:DIAG] yaw basis: no FPP camera")
        return
    end

    local okCurrent, current = pcall(_callGetLocalOrientation, cam)
    if not okCurrent or not current then
        print("[HeadTracking:DIAG] yaw basis: GetLocalOrientation failed")
        return
    end

    local clean = quatNormalize(current)
    if self.last_head_quat then
        clean = quatNormalize(quatMul(clean, quaternionInverse(self.last_head_quat)))
    end

    local worldFromActive = getActiveCameraWorldOrientation()
    local worldFromPlayer = clean
    local okP, pw = pcall(_callGetWorldOrientation, player)
    if okP and pw and isValidNumber(pw.i) and isValidNumber(pw.j)
                  and isValidNumber(pw.k) and isValidNumber(pw.r) then
        worldFromPlayer = quatNormalize(quatMul(quatNormalize(pw), clean))
    end

    local localHead = quatNormalize(EulerAngles.new(0, 0, 35):ToQuat())
    local worldHeadActive = worldFromActive and quatNormalize(composeWorldModeQuat(worldFromActive, 0, 0, 35)) or nil
    local worldHeadPlayer = quatNormalize(composeWorldModeQuat(worldFromPlayer, 0, 0, 35))
    local solvedHeadPlayer = nil
    local finalLocal = nil
    local finalWorld = nil
    local okP2, pw2 = pcall(_callGetWorldOrientation, player)
    if okP2 and pw2 and isValidNumber(pw2.i) and isValidNumber(pw2.j)
                  and isValidNumber(pw2.k) and isValidNumber(pw2.r) then
        local parentWorld = quatNormalize(pw2)
        local cleanWorld = quatNormalize(quatMul(parentWorld, clean))
        local yawWorld = EulerAngles.new(0, 0, 35):ToQuat()
        local desiredWorld = quatNormalize(quatMul(yawWorld, cleanWorld))
        finalLocal = quatNormalize(quatMul(quaternionInverse(parentWorld), desiredWorld))
        solvedHeadPlayer = quatNormalize(quatMul(quaternionInverse(clean), finalLocal))
        finalWorld = quatNormalize(quatMul(parentWorld, quatNormalize(quatMul(clean, solvedHeadPlayer))))
    end

    local function fmt(q)
        if not q then return "nil" end
        local p, y, r = quatToPYR(q)
        return string.format("q=(%.3f %.3f %.3f %.3f) pyr=(%s %s %s)",
            q.i, q.j, q.k, q.r,
            tostring(p and string.format("%.1f", p)),
            tostring(y and string.format("%.1f", y)),
            tostring(r and string.format("%.1f", r)))
    end

    print("[HeadTracking:DIAG] yaw basis cleanLocal " .. fmt(clean))
    print("[HeadTracking:DIAG] yaw basis worldFromPlayer " .. fmt(worldFromPlayer))
    print("[HeadTracking:DIAG] yaw basis worldFromActive " .. fmt(worldFromActive))
    print("[HeadTracking:DIAG] yaw basis localHead35 " .. fmt(localHead))
    print("[HeadTracking:DIAG] yaw basis worldHead35.player " .. fmt(worldHeadPlayer))
    print("[HeadTracking:DIAG] yaw basis worldHead35.active " .. fmt(worldHeadActive))
    print("[HeadTracking:DIAG] yaw basis solvedHead35.player " .. fmt(solvedHeadPlayer))
    print("[HeadTracking:DIAG] yaw basis finalLocal35.player " .. fmt(finalLocal))
    print("[HeadTracking:DIAG] yaw basis finalWorld35.player " .. fmt(finalWorld))
    print(string.format(
        "[HeadTracking:DIAG] yaw basis delta local-vs-solved=%s",
        solvedHeadPlayer and string.format("%.6f", quatDelta(localHead, solvedHeadPlayer)) or "nil"))

    local f = io.open("yaw-diag.log", "a")
    if f then
        f:write("[basis] cleanLocal " .. fmt(clean) .. "\n")
        f:write("[basis] worldFromPlayer " .. fmt(worldFromPlayer) .. "\n")
        f:write("[basis] worldFromActive " .. fmt(worldFromActive) .. "\n")
        f:write("[basis] localHead35 " .. fmt(localHead) .. "\n")
        f:write("[basis] worldHead35.player " .. fmt(worldHeadPlayer) .. "\n")
        f:write("[basis] worldHead35.active " .. fmt(worldHeadActive) .. "\n")
        f:write("[basis] solvedHead35.player " .. fmt(solvedHeadPlayer) .. "\n")
        f:write("[basis] finalLocal35.player " .. fmt(finalLocal) .. "\n")
        f:write("[basis] finalWorld35.player " .. fmt(finalWorld) .. "\n")
        f:write("[basis] delta local-vs-solved=" ..
            (solvedHeadPlayer and string.format("%.6f", quatDelta(localHead, solvedHeadPlayer)) or "nil") .. "\n")
        f:close()
    end
end

--- Get the current smoothed rotation values being applied.
--- Returns a per-instance reusable table - callers must NOT cache the table
--- reference across frames (the values mutate). This avoids the per-call
--- table allocation, which adds up since the per-frame onUpdate AND onDraw
--- paths both call this every frame at 60-144Hz.
--- @return table {yaw, pitch, roll} smoothed values in degrees
function Camera:getSmoothedRotation()
    local r = self._smoothed_rotation_buf
    if not r then
        r = { yaw = 0, pitch = 0, roll = 0 }
        self._smoothed_rotation_buf = r
    end
    r.yaw = self.smooth_yaw
    r.pitch = self.smooth_pitch
    r.roll = self.smooth_roll
    return r
end

--- Get the last head rotation quaternion computed by apply(). Used by
--- modules/aim.lua to hand the C++ view-matrix hook an identical
--- rotation (avoids any Euler-vs-quat drift between the two sides).
--- Returns the CURRENTLY-computed quat even when skip_cam_write was set,
--- so the native hook always has fresh data. Identity if apply() hasn't
--- run yet.
--- @return Quaternion
function Camera:getHeadQuat()
    if self._computed_head_quat then return self._computed_head_quat end
    if self.last_head_quat then return self.last_head_quat end
    return Quaternion.new(0, 0, 0, 1)
end

--- Decompose the head quaternion that was actually applied to the camera
--- back to local YPR. Differs from getSmoothedRotation() in world-yaw mode,
--- where smooth_yaw is re-based onto the clean orientation before being
--- applied; the reticle projection must use these decomposed values, not the
--- smoothing inputs, or it desyncs from the rendered camera during head motion.
--- @return number yaw, number pitch, number roll (degrees)
function Camera:getAppliedYPR()
    local q = self:getHeadQuat()
    local p, y, r = quatToPYR(q)
    return y or 0, p or 0, r or 0
end

--- Decompose the head rotation as it is *rendered* (vs. just applied this
--- logic frame), with optional forward extrapolation.
---
--- The rendered camera state can run slightly ahead of the head_quat we
--- wrote (engine smoothing, sub-frame timing, DLSS-G/MFG interpolation).
--- Reticle drift in head-motion direction during motion that settles
--- correctly at rest is the symptom: per-frame head delta is moving
--- the displayed camera further than the latest head_quat encodes.
---
--- `lead` extrapolates the YPR forward by that many frames of per-frame
--- delta. 0 = no extrapolation (returns current). At rest, prev == curr,
--- so the extrapolation collapses to current and the rest position stays
--- correct regardless of `lead`.
--- @param lead number|nil Frames of per-frame delta to extrapolate (default 0).
--- @return number yaw, number pitch, number roll (degrees)
function Camera:getRenderedYPR(lead)
    local curr_q = self:getHeadQuat()
    local cp, cy, cr = quatToPYR(curr_q)

    -- ToEulerAngles can fail intermittently on some quat states (CET pcall
    -- guard catches it); without this cache, a single failure frame snaps
    -- the reticle to screen center. Hold the last good decomposition and
    -- reuse it on failure so the reticle stays put.
    if cp == nil or cy == nil or cr == nil then
        local last = self._last_good_applied_ypr
        if last then return last.y, last.p, last.r end
        return 0, 0, 0
    end

    self._last_good_applied_ypr = self._last_good_applied_ypr or {}
    self._last_good_applied_ypr.p = cp
    self._last_good_applied_ypr.y = cy
    self._last_good_applied_ypr.r = cr

    if not lead or lead <= 0 or not self._prev_head_quat then
        return cy, cp, cr
    end

    local pp, py, pr = quatToPYR(self._prev_head_quat)
    -- If prev decompose fails, skip extrapolation rather than corrupting
    -- the delta with a zero baseline.
    if pp == nil or py == nil or pr == nil then
        return cy, cp, cr
    end

    -- Per-axis Euler extrapolation. Adjacent-frame head deltas are small
    -- (degrees, not radians), so Euler-space extrapolation is well-defined
    -- and avoids slerp gimbal cases.
    local y = cy + (cy - py) * lead
    local p = cp + (cp - pp) * lead
    local r = cr + (cr - pr) * lead
    return y, p, r
end

--- Get the last raw values received from the tracker
--- @return table {yaw, pitch, roll} raw values in degrees
function Camera:getRawRotation()
    return {
        yaw = self.last_raw_yaw,
        pitch = self.last_raw_pitch,
        roll = self.last_raw_roll
    }
end

--- Get statistics for debugging
--- @return table Statistics {update_count, last_applied_yaw, last_applied_pitch, last_applied_roll}
function Camera:getStats()
    return {
        update_count = self.stats.update_count,
        last_applied_yaw = self.stats.last_applied_yaw,
        last_applied_pitch = self.stats.last_applied_pitch,
        last_applied_roll = self.stats.last_applied_roll,
        recenter_offset = self:getRecenterOffset()
    }
end

--- Reset statistics counters
function Camera:resetStats()
    self.stats.update_count = 0
    self.stats.last_applied_yaw = 0
    self.stats.last_applied_pitch = 0
    self.stats.last_applied_roll = 0
end

return Camera
