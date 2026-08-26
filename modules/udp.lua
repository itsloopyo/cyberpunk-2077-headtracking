-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Tracking Data Receiver Module
-- Reads head pose from the native RED4ext plugin.
--
-- The plugin registers two global RTTI functions (native/src/ScriptChannel.cpp)
-- and we call them straight out of CET as game functions:
--
--   Game.HeadTrackingPollPose()  -> ok, yaw, pitch, roll, x, y, z, flags
--   Game.HeadTrackingPushState(yaw, pitch, roll, enabled, isAds,
--                              qi, qj, qk, qr, propagatorInject,
--                              positionX, positionY, positionZ, aimDistance,
--                              chaseCamera) -> ok
--   Game.HeadTrackingSetFppOrientation(qi, qj, qk, qr, active) -> ok
--   Game.HeadTrackingPushRicochetState(valid, hit, normal, forward) -> ok
--
-- This used to be a TCP socket served by the plugin and driven from Lua by
-- RedSocket, a separate CET mod. That mod was never shipped with ours, so any
-- user who did not already have it installed got a fatal error here, a dead
-- mod, and a native log that looked completely healthy. A direct call has no
-- transport to be missing, and no connect / retry / pending-request state to
-- wedge.

local TrackingInput = {}
TrackingInput.__index = TrackingInput

local DATA_FRESHNESS_WINDOW_S = 0.5

-- Reusable parsed-data table to avoid GC pressure.
local reusable_data = { yaw = 0, pitch = 0, roll = 0, x = 0, y = 0, z = 0, seq = 0 }

-- native_flags bit layout, mirrored in native/src/ScriptChannel.cpp. Bits 1 and
-- 6 are live status (hook activity, connection locality); bits 3-5 and 7 are
-- one-shot edges that native sets when a chord/key transitions to down, and
-- Lua clears on consume.
local FLAG_CAMERA_ACTIVE     = 2   -- bit 1
local FLAG_TOGGLE_TRACKING   = 8   -- bit 3
local FLAG_CYCLE_MODE        = 16  -- bit 4
local FLAG_TOGGLE_YAW        = 32  -- bit 5
local FLAG_REMOTE_CONNECTION = 64  -- bit 6, live status (not an edge)
local FLAG_CYCLE_ADS_MODE    = 128 -- bit 7

local function hasFlag(flags, bit)
    return (math.floor(flags / bit) % 2) >= 1
end

local total_packets = 0
local poll_count = 0
local native_flags = 0
local last_successful_parse_time = nil
-- Whether the vehicle chase camera is what the player is looking through.
-- Kept beside native_state rather than in it: the suppressed path pushes
-- through poll() without ever calling setNativeState, and the native side has
-- to hear "not the chase camera" on those frames too or it keeps injecting
-- into the render params off a stale flag.
local chase_camera_active = false
local native_toggle_tracking_requested = false
local native_cycle_mode_requested = false
local native_toggle_yaw_requested = false
local native_cycle_ads_mode_requested = false

-- Hoisted call trampolines. `pcall(function() ... end)` allocates a fresh
-- closure per invocation and both of these run every frame, so the arguments
-- ride in upvalues instead. Neither is reentrant, which is what makes the
-- upvalue reuse safe (same reasoning as guardedVar in init.lua).
local push_args = { 0, 0, 0, false, false, 0, 0, 0, 1, false, 0, 0, 0, 0, false }
local ricochet_args = { false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
local function _callPush()
    return Game.HeadTrackingPushState(
        push_args[1], push_args[2], push_args[3], push_args[4], push_args[5],
        push_args[6], push_args[7], push_args[8], push_args[9], push_args[10],
        push_args[11], push_args[12], push_args[13], push_args[14],
        push_args[15])
end
local function _callPushRicochet()
    return Game.HeadTrackingPushRicochetState(
        ricochet_args[1], ricochet_args[2], ricochet_args[3], ricochet_args[4],
        ricochet_args[5], ricochet_args[6], ricochet_args[7],
        ricochet_args[8], ricochet_args[9], ricochet_args[10],
        ricochet_args[11], ricochet_args[12], ricochet_args[13])
end
local function _callPoll()
    return Game.HeadTrackingPollPose()
end

function TrackingInput.new()
    local self = setmetatable({}, TrackingInput)
    self.initialized = false
    self.native_state = nil
    return self
end

function TrackingInput:init()
    -- The plugin registers these when the game builds its RTTI registry, which
    -- happens long before onInit, so a missing function here means the plugin
    -- is not loaded at all - a stale RED4ext install, a failed load, or the DLL
    -- never deployed. Nothing downstream works without it, so say which half is
    -- missing rather than failing later with a nil call.
    if type(Game.HeadTrackingPollPose) ~= "function" or
       type(Game.HeadTrackingPushState) ~= "function" or
       type(Game.HeadTrackingSetFppOrientation) ~= "function" or
       type(Game.HeadTrackingPushRicochetState) ~= "function" then
        error("[HeadTracking] FATAL: the native plugin's script functions are missing. " ..
              "Check that red4ext/plugins/HeadTrackingAim.dll is installed. If " ..
              "HeadTracking.log is missing beside the game EXE the plugin never " ..
              "loaded; red4ext/logs/red4ext.log says why.")
    end

    self.initialized = true
    print("[HeadTracking] Native tracking input ready")
    return true
end

function TrackingInput:isReady()
    return self.initialized
end

function TrackingInput:isDataFresh()
    if not last_successful_parse_time then return false end
    return (os.clock() - last_successful_parse_time) <= DATA_FRESHNESS_WINDOW_S
end

function TrackingInput:setNativeState(yaw, pitch, roll, enabled, is_ads, quat,
                                      propagator_inject, position_x, position_y,
                                      position_z, aim_distance, ricochet_hit_valid,
                                      ricochet_hit_x, ricochet_hit_y, ricochet_hit_z,
                                      ricochet_normal_x, ricochet_normal_y, ricochet_normal_z,
                                      ricochet_forward_x, ricochet_forward_y,
                                      ricochet_forward_z, ricochet_end_x,
                                      ricochet_end_y, ricochet_end_z)
    -- Reuse the state table to avoid a 10-field heap allocation every frame
    -- (this is called once per onUpdate via Aim:update). The table is left nil
    -- until the first call so poll() knows there is nothing to push yet.
    local st = self.native_state
    if not st then
        st = {}
        self.native_state = st
    end
    st.yaw = yaw or 0
    st.pitch = pitch or 0
    st.roll = roll or 0
    st.enabled = enabled and true or false
    st.is_ads = is_ads and true or false
    st.qi = quat and quat.i or 0
    st.qj = quat and quat.j or 0
    st.qk = quat and quat.k or 0
    st.qr = quat and quat.r or 1
    st.propagator_inject = propagator_inject and true or false
    st.position_x = position_x or 0
    st.position_y = position_y or 0
    st.position_z = position_z or 0
    st.aim_distance = aim_distance or 0
    st.ricochet_hit_valid = ricochet_hit_valid and true or false
    st.ricochet_hit_x = ricochet_hit_x or 0
    st.ricochet_hit_y = ricochet_hit_y or 0
    st.ricochet_hit_z = ricochet_hit_z or 0
    st.ricochet_normal_x = ricochet_normal_x or 0
    st.ricochet_normal_y = ricochet_normal_y or 0
    st.ricochet_normal_z = ricochet_normal_z or 0
    st.ricochet_forward_x = ricochet_forward_x or 0
    st.ricochet_forward_y = ricochet_forward_y or 0
    st.ricochet_forward_z = ricochet_forward_z or 0
    st.ricochet_end_x = ricochet_end_x or 0
    st.ricochet_end_y = ricochet_end_y or 0
    st.ricochet_end_z = ricochet_end_z or 0
end

--- Tell the native side which camera the head rotation has to reach this
--- frame. True hands it to the ViewBuilder hook (the chase camera's only
--- route) and stands the aim peels down, because in that camera no head
--- rotation was ever written into camera state for them to peel.
--- @param active boolean
function TrackingInput:setChaseCamera(active)
    chase_camera_active = active and true or false
end

function TrackingInput:isNativeCameraHookActive()
    return hasFlag(native_flags, FLAG_CAMERA_ACTIVE)
end

--- True when the tracking data is arriving from a remote network device
--- rather than from this machine. The native UDP receiver classifies the
--- sender address (loopback = local, anything else = remote) and publishes
--- it as a live status bit, so this re-evaluates on every poll.
--- @return boolean
function TrackingInput:isRemoteConnection()
    return hasFlag(native_flags, FLAG_REMOTE_CONNECTION)
end

-- One-shot edge consumers. Each returns true exactly once per native
-- "key went down" event, then false until the next edge. Kept as explicit
-- functions instead of a closure-based helper because they run
-- every frame and this module deliberately avoids per-frame allocations.
function TrackingInput:consumeNativeToggleTrackingRequested()
    if native_toggle_tracking_requested then
        native_toggle_tracking_requested = false
        return true
    end
    return false
end

function TrackingInput:consumeNativeCycleModeRequested()
    if native_cycle_mode_requested then
        native_cycle_mode_requested = false
        return true
    end
    return false
end

function TrackingInput:consumeNativeToggleYawRequested()
    if native_toggle_yaw_requested then
        native_toggle_yaw_requested = false
        return true
    end
    return false
end

function TrackingInput:consumeNativeCycleAdsModeRequested()
    if native_cycle_ads_mode_requested then
        native_cycle_ads_mode_requested = false
        return true
    end
    return false
end

function TrackingInput:secondsSinceLastPacket()
    if not last_successful_parse_time then return math.huge end
    return os.clock() - last_successful_parse_time
end

--- Push last frame's processed state, then read the latest tracker sample.
--- @return table|nil {yaw, pitch, roll, x, y, z}
function TrackingInput:poll()
    if not self.initialized then return nil end

    local st = self.native_state
    if st then
        push_args[1] = st.yaw
        push_args[2] = st.pitch
        push_args[3] = st.roll
        push_args[4] = st.enabled
        push_args[5] = st.is_ads
        push_args[6] = st.qi
        push_args[7] = st.qj
        push_args[8] = st.qk
        push_args[9] = st.qr
        push_args[10] = st.propagator_inject
        push_args[11] = st.position_x
        push_args[12] = st.position_y
        push_args[13] = st.position_z
        push_args[14] = st.aim_distance
        push_args[15] = chase_camera_active
        ricochet_args[1] = st.ricochet_hit_valid
        ricochet_args[2] = st.ricochet_hit_x
        ricochet_args[3] = st.ricochet_hit_y
        ricochet_args[4] = st.ricochet_hit_z
        ricochet_args[5] = st.ricochet_normal_x
        ricochet_args[6] = st.ricochet_normal_y
        ricochet_args[7] = st.ricochet_normal_z
        ricochet_args[8] = st.ricochet_forward_x
        ricochet_args[9] = st.ricochet_forward_y
        ricochet_args[10] = st.ricochet_forward_z
        ricochet_args[11] = st.ricochet_end_x
        ricochet_args[12] = st.ricochet_end_y
        ricochet_args[13] = st.ricochet_end_z
        pcall(_callPush)
        pcall(_callPushRicochet)
    end

    poll_count = poll_count + 1

    local ok, has_data, yaw, pitch, roll, x, y, z, flags = pcall(_callPoll)
    if not ok or not has_data then return nil end

    native_flags = flags or 0
    if hasFlag(native_flags, FLAG_TOGGLE_TRACKING) then native_toggle_tracking_requested = true end
    if hasFlag(native_flags, FLAG_CYCLE_MODE)      then native_cycle_mode_requested      = true end
    if hasFlag(native_flags, FLAG_TOGGLE_YAW)      then native_toggle_yaw_requested      = true end
    if hasFlag(native_flags, FLAG_CYCLE_ADS_MODE)  then native_cycle_ads_mode_requested  = true end

    -- NaN check. Everything else the native side already validated.
    if yaw ~= yaw or pitch ~= pitch or roll ~= roll then return nil end
    if x ~= x or y ~= y or z ~= z then x, y, z = 0, 0, 0 end

    total_packets = total_packets + 1
    reusable_data.yaw = yaw
    reusable_data.pitch = pitch
    reusable_data.roll = roll
    reusable_data.x = x or 0
    reusable_data.y = y or 0
    reusable_data.z = z or 0
    reusable_data.seq = poll_count
    last_successful_parse_time = os.clock()
    return reusable_data
end

function TrackingInput:getStats()
    local now = os.clock()
    local is_receiving = last_successful_parse_time ~= nil and (now - last_successful_parse_time) < 1.0
    return {
        packet_count = total_packets,
        last_packet_time = last_successful_parse_time,
        is_receiving = is_receiving,
        connected = self.initialized,
    }
end

function TrackingInput:resetStats()
    total_packets = 0
    last_successful_parse_time = nil
end

function TrackingInput:close()
    self.initialized = false
    print("[HeadTracking] Native tracking input closed")
end

return TrackingInput
