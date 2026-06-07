-- Aim Compensation Module
-- Communicates with RED4ext C++ plugin via shared memory for native aim compensation
--
-- When head tracking rotates the camera, bullets would normally land at the new
-- screen center. The C++ plugin hooks native aim functions and rotates by the INVERSE
-- of head tracking rotation, so bullets land at the original aim point.
--
-- This Lua module writes state to shared memory; C++ plugin reads it.

-- FFI is only available after onInit. Defer all imports/cdefs until init().
local ffi = nil
local INVALID_HANDLE_VALUE = nil
local cdef_done = false

local Aim = {}
Aim.__index = Aim

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

-- Windows constants (cheap; FFI not required to define them).
local PAGE_READWRITE = 0x04
local FILE_MAP_ALL_ACCESS = 0xF001F
local SHARED_MEM_NAME = "HeadTrackingAimState"

--- Lazily import FFI and register C declarations. CET only exposes the FFI
--- module after onInit fires, so this MUST NOT run at module-load time.
local function ensureFfi()
    if ffi then return true end

    local ok, mod = pcall(require, "ffi")
    if not ok or type(mod) ~= "table" then
        return false, "FFI module not available (require returned " .. type(mod) .. ")"
    end
    ffi = mod

    if not cdef_done then
        -- MUST stay in lockstep with native/src/SharedState.hpp. Field
        -- order, sizes and padding are both compilers' shared contract;
        -- mismatches silently corrupt whoever reads the wrong offsets.
        local cdef_ok, cdef_err = pcall(ffi.cdef, [[
            typedef struct {
                /* === Section 1: Lua -> native (processed pose) === */
                float yaw;
                float pitch;
                float roll;
                bool  enabled;
                bool  is_ads;
                bool  camera_hook_inject;
                uint8_t pad0;
                uint32_t frame;
                float ads_scale;
                float quat_i, quat_j, quat_k, quat_r;
                uint32_t applied_frame;

                /* === Section 2: native -> Lua (raw UDP) === */
                float raw_yaw;
                float raw_pitch;
                float raw_roll;
                float raw_x;
                float raw_y;
                float raw_z;
                uint32_t raw_frame;
                uint64_t raw_timestamp_ms;

                /* === Section 3: native -> Lua (camera hook status) === */
                bool camera_hook_active;
                uint8_t pad1[3];
                uint32_t camera_hook_fires;

                /* === Section 4: native -> Lua (Running::OnUpdate status) === */
                uint32_t native_running_frame;

                /* === Section 5: Lua <-> native (SNAP-CLEAN restore handoff) === */
                bool     pending_native_restore;
                uint8_t  pad2[3];
                float    restore_quat_i;
                float    restore_quat_j;
                float    restore_quat_k;
                float    restore_quat_r;
                uint32_t restore_req_seq;
                uint32_t restore_ack_seq;
                uint32_t restore_fires;
                uint32_t shot_marker_seq;

                /* === Section 6: native -> Lua (hitscan hook status) === */
                bool     hitscan_hook_active;
                uint8_t  pad3[3];
                uint32_t hitscan_hook_fires;

                /* === Section 7: Lua -> native (cam-propagator decouple gate) === */
                uint32_t propagator_inject_active;
                uint32_t propagator_hook_fires;

                /* === Section 8: Lua -> native (FreezeFrameHook gate) === */
                uint32_t freeze_frame_enabled;
            } HeadTrackingState;

            void* CreateFileMappingA(void* hFile, void* lpAttr,
                uint32_t flProtect, uint32_t dwMaxHigh, uint32_t dwMaxLow, const char* lpName);
            void* OpenFileMappingA(uint32_t dwDesiredAccess, bool bInheritHandle, const char* lpName);
            void* MapViewOfFile(void* hFileMappingObject, uint32_t dwDesiredAccess,
                uint32_t dwFileOffsetHigh, uint32_t dwFileOffsetLow, size_t dwNumberOfBytesToMap);
            bool UnmapViewOfFile(const void* lpBaseAddress);
            bool CloseHandle(void* hObject);
            uint32_t GetLastError();
        ]])
        if not cdef_ok then
            -- "redefinition" is fine - udp.lua may have already cdef'd the same types.
            local err = tostring(cdef_err)
            if not err:find("redefinition", 1, true) and not err:find("redefined", 1, true) then
                return false, "ffi.cdef failed: " .. err
            end
        end
        cdef_done = true
    end

    INVALID_HANDLE_VALUE = ffi.cast("void*", -1)
    return true
end

-- Shared memory state
local shared_mem = {
    handle = nil,
    state = nil,
    frame_counter = 0,
    initialized = false
}

--- Initialize shared memory for C++ plugin communication
--- @return boolean success
local function initSharedMemory()
    if shared_mem.initialized then
        return true
    end

    -- Try to open existing shared memory first (C++ plugin may have created it)
    local handle = ffi.C.OpenFileMappingA(FILE_MAP_ALL_ACCESS, false, SHARED_MEM_NAME)

    if handle == nil or handle == ffi.cast("void*", 0) then
        -- Create new shared memory region
        handle = ffi.C.CreateFileMappingA(
            INVALID_HANDLE_VALUE,
            nil,
            PAGE_READWRITE,
            0,
            ffi.sizeof("HeadTrackingState"),
            SHARED_MEM_NAME
        )

        if handle == nil or handle == ffi.cast("void*", 0) then
            local err = ffi.C.GetLastError()
            print(string.format("[HeadTracking:AIM] Failed to create shared memory, error=%d", err))
            return false
        end
        print("[HeadTracking:AIM] Created shared memory region")
    else
        print("[HeadTracking:AIM] Opened existing shared memory region")
    end

    -- Map view of file
    local state_ptr = ffi.C.MapViewOfFile(handle, FILE_MAP_ALL_ACCESS, 0, 0, 0)

    if state_ptr == nil or state_ptr == ffi.cast("void*", 0) then
        local err = ffi.C.GetLastError()
        print(string.format("[HeadTracking:AIM] Failed to map view of file, error=%d", err))
        ffi.C.CloseHandle(handle)
        return false
    end

    shared_mem.handle = handle
    shared_mem.state = ffi.cast("HeadTrackingState*", state_ptr)
    shared_mem.initialized = true

    -- Initialize state to disabled. Keep the quat at identity (0,0,0,1) so
    -- the C++ view-matrix hook sees "no data yet" and skips injection.
    shared_mem.state.yaw = 0
    shared_mem.state.pitch = 0
    shared_mem.state.roll = 0
    shared_mem.state.enabled = false
    shared_mem.state.is_ads = false
    shared_mem.state.camera_hook_inject = false
    shared_mem.state.frame = 0
    shared_mem.state.ads_scale = 0.2
    shared_mem.state.quat_i = 0
    shared_mem.state.quat_j = 0
    shared_mem.state.quat_k = 0
    shared_mem.state.quat_r = 1
    shared_mem.state.applied_frame = 0

    shared_mem.state.pending_native_restore = false
    shared_mem.state.restore_quat_i = 0
    shared_mem.state.restore_quat_j = 0
    shared_mem.state.restore_quat_k = 0
    shared_mem.state.restore_quat_r = 1
    shared_mem.state.restore_req_seq = 0
    shared_mem.state.restore_ack_seq = 0
    shared_mem.state.restore_fires = 0
    shared_mem.state.shot_marker_seq = 0

    shared_mem.state.propagator_inject_active = 0
    shared_mem.state.propagator_hook_fires = 0

    shared_mem.state.freeze_frame_enabled = 1

    print("[HeadTracking:AIM] Shared memory initialized successfully")
    return true
end

--- Shutdown shared memory
local function shutdownSharedMemory()
    if not shared_mem.initialized then
        return
    end

    if shared_mem.state ~= nil then
        ffi.C.UnmapViewOfFile(shared_mem.state)
        shared_mem.state = nil
    end

    if shared_mem.handle ~= nil then
        ffi.C.CloseHandle(shared_mem.handle)
        shared_mem.handle = nil
    end

    shared_mem.initialized = false
    print("[HeadTracking:AIM] Shared memory shutdown")
end

--- Update shared memory with current state.
--- Writes the processed Euler pose + head quaternion so both the
--- aim-compensation hook (needs yaw/pitch) and the view-matrix hook
--- (needs the quat) see the same rotation.
--- @param yaw number Current yaw in degrees (processed, signed)
--- @param pitch number Current pitch in degrees (processed, signed)
--- @param enabled boolean Whether tracking is active this frame
--- @param is_ads boolean Whether aiming down sights
--- @param ads_scale number|nil ADS effect multiplier (default 0.2)
--- @param roll number|nil Current roll in degrees (optional, defaults to 0)
--- @param quat table|nil Head rotation quaternion {i,j,k,r}; if nil, keep last
local _shm_diag_calls = 0
local _shm_diag_last_logged = 0

local function updateSharedMemory(yaw, pitch, enabled, is_ads, ads_scale, roll, quat)
    if not shared_mem.initialized or shared_mem.state == nil then
        return
    end

    _shm_diag_calls = _shm_diag_calls + 1

    shared_mem.state.yaw = yaw
    shared_mem.state.pitch = pitch
    shared_mem.state.roll = roll or 0
    shared_mem.state.enabled = enabled
    shared_mem.state.is_ads = is_ads or false
    shared_mem.state.ads_scale = ads_scale or 0.2
    -- The C++ view-matrix hook uses camera_hook_inject as a per-frame gate
    -- that mirrors `enabled`. Keeping it as a separate flag leaves room
    -- for future "enabled but don't inject this frame" states (e.g. ADS
    -- mode overrides).
    shared_mem.state.camera_hook_inject = enabled

    if quat then
        shared_mem.state.quat_i = quat.i or 0
        shared_mem.state.quat_j = quat.j or 0
        shared_mem.state.quat_k = quat.k or 0
        shared_mem.state.quat_r = quat.r or 1
        shared_mem.state.applied_frame = (shared_mem.state.applied_frame or 0) + 1
    end

    shared_mem.frame_counter = shared_mem.frame_counter + 1
    shared_mem.state.frame = shared_mem.frame_counter
end

--- Read the C++ camera-hook liveness flag from shared memory.
--- @return boolean Whether the native view-matrix hook is attached AND firing
local function readCameraHookActive()
    if not shared_mem.initialized or shared_mem.state == nil then
        return false
    end
    return shared_mem.state.camera_hook_active == true
end

local function readHitscanHookActive()
    if not shared_mem.initialized or shared_mem.state == nil then
        return false
    end
    return shared_mem.state.hitscan_hook_active == true
       and (tonumber(shared_mem.state.applied_frame) or 0) > 0
end

--- Read the native Running::OnUpdate frame counter. Used to confirm the
--- RED4ext per-frame hook is actually firing (should tick at the game
--- frame rate if the plugin is loaded and the mechanism works).
--- @return number native_running_frame (0 if shm not available)
local function readNativeRunningFrame()
    if not shared_mem.initialized or shared_mem.state == nil then
        return 0
    end
    return tonumber(shared_mem.state.native_running_frame) or 0
end

--- Read the native-side SNAP-CLEAN restore ack counter. Matches the
--- req_seq of the last publish the native OnUpdate consumed. When
--- ack_seq == req_seq, native has seen and (in phase 2b) performed the
--- restore; Lua can skip its fallback tickSnapRestore that frame.
--- @return number ack_seq (0 if shm not available)
local function readRestoreAckSeq()
    if not shared_mem.initialized or shared_mem.state == nil then
        return 0
    end
    return tonumber(shared_mem.state.restore_ack_seq) or 0
end

--- Read the native-side SNAP-CLEAN request-seq we've published so far.
--- @return number req_seq
local function readRestoreReqSeq()
    if not shared_mem.initialized or shared_mem.state == nil then
        return 0
    end
    return tonumber(shared_mem.state.restore_req_seq) or 0
end

--- Write a SNAP-CLEAN restore request into shared memory. Writes the
--- quat BEFORE flipping the flag so the native consumer never sees a
--- stale/partial quat; that matches the TcpServer-side parser's ordering.
--- Also bumps restore_req_seq which native mirrors into restore_ack_seq
--- when it consumes the request.
--- @param qi number quaternion i
--- @param qj number quaternion j
--- @param qk number quaternion k
--- @param qr number quaternion r
--- @return boolean wrote true if SHM path was taken
local function shmPublishRestore(qi, qj, qk, qr)
    if not shared_mem.initialized or shared_mem.state == nil then
        return false
    end
    local s = shared_mem.state
    s.restore_quat_i = qi
    s.restore_quat_j = qj
    s.restore_quat_k = qk
    s.restore_quat_r = qr
    s.restore_req_seq = (tonumber(s.restore_req_seq) or 0) + 1
    s.pending_native_restore = true
    return true
end

local function shmPublishShotMarker()
    if not shared_mem.initialized or shared_mem.state == nil then
        return false
    end
    local s = shared_mem.state
    s.shot_marker_seq = (tonumber(s.shot_marker_seq) or 0) + 1
    return true
end

-- Module-level state shared with Override callback
-- Must be outside the class for the Override closure to access it
local aim_state = {
    enabled = false,
    is_ads = false,
    ads_scale = 0.2,  -- 20% effect during ADS
    smooth_yaw = 0,
    smooth_pitch = 0,
    smooth_roll = 0,
    head_quat = { i = 0, j = 0, k = 0, r = 1 },
    override_registered = false,
    shared_mem_initialized = false,
    -- Cached "is the C++ view-matrix hook live?" flag. Polled each
    -- update() from shared memory so camera.lua can branch on it.
    native_camera_hook_active = false,
    native_hitscan_hook_active = false,
    native_hitscan_skip_logged = false,
    native_hitscan_window_publishes = 0,
    clean_cam_snap_skip_logged = false,
    settings = nil,
    -- UDP/TCP tracking input. Set via Aim:setUdp() from init.lua so the
    -- SNAP-CLEAN Observer can publish the restore quat to native over
    -- the TCP control channel even when CET's FFI (and thus our SHM
    -- path) is disabled.
    udp = nil,
    snap_clean_enabled = true,
    -- Experimental: while the fire button is HELD, hold cam+0xD0 clean every
    -- frame (after camera:apply) so the NATIVE auto-fire loop's per-shot reads
    -- see the mouse-only orientation, not just the first trigger-pull. Tests
    -- whether automatic follow-up shots read cam+0xD0 at all. Tradeoff: the
    -- view de-tracks (snaps mouse-forward) during sustained fire. PROVEN
    -- 2026-05-28: works for bullets but de-tracks the view unacceptably,
    -- because cam+0xD0 is the single shared view+aim slot. Default OFF; kept
    -- behind DiagHoldClean for reference. The acceptable fix is a sub-frame
    -- native bracket of the auto-fire's own cam+0xD0 read site.
    hold_clean_while_firing = false,
    firing_held = false,
}

-- Pre-cache math functions
local math_rad = math.rad
local math_cos = math.cos
local math_sin = math.sin
local math_abs = math.abs

-- Hoisted pcall trampolines so the per-frame / per-shot paths don't allocate
-- a closure per call. Mirrors the same optimisation in modules/camera.lua.
local function _camGetLocalOrientation(cam)
    return cam:GetLocalOrientation()
end
local function _camSetLocalOrientation(cam, q)
    cam:SetLocalOrientation(q)
end

-- Debug logging
local aim_debug_counter = 0
local AIM_DEBUG_INTERVAL = 120
local SNAP_CLEAN_MIN_INTERVAL_SECONDS = 0.0

--- Rotate a Vector4 direction by yaw and pitch angles
--- @param vec table Vector4 direction to rotate
--- @param yaw_deg number Yaw rotation in degrees (around Z axis)
--- @param pitch_deg number Pitch rotation in degrees (around X axis)
--- @return table Rotated Vector4 direction
local function rotateVectorByAngles(vec, yaw_deg, pitch_deg)
    local yaw = math_rad(yaw_deg)
    local pitch = math_rad(pitch_deg)

    local cy = math_cos(yaw)
    local sy = math_sin(yaw)
    local cp = math_cos(pitch)
    local sp = math_sin(pitch)

    -- Extract components (Cyberpunk uses Y-forward, Z-up coordinate system)
    local x = vec.x
    local y = vec.y
    local z = vec.z

    -- Apply yaw rotation (around Z axis)
    local x1 = x * cy - y * sy
    local y1 = x * sy + y * cy
    local z1 = z

    -- Apply pitch rotation (around X axis, after yaw)
    local x2 = x1
    local y2 = y1 * cp - z1 * sp
    local z2 = y1 * sp + z1 * cp

    return Vector4.new(x2, y2, z2, vec.w)
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
    aim_state.settings = settings

    return self
end

--- Initialize aim compensation (shared memory + legacy Override hooks)
--- Must be called once during mod initialization
--- @return boolean success
function Aim:init()
    -- CET Override() does NOT require FFI - register the aim-decoupling
    -- overrides first so they work even when the shared-memory path doesn't.
    -- FFI is only needed by the C++ plugin's shared-state fallback, which
    -- is redundant now that the Lua overrides catch the real aim path.

    -- Try to bring up FFI for shared memory (best-effort, non-fatal).
    local ffi_ok, ffi_err = ensureFfi()
    if ffi_ok then
        if not aim_state.shared_mem_initialized then
            if initSharedMemory() then
                aim_state.shared_mem_initialized = true
                dlog("[HeadTracking:AIM] Shared memory communication ready for C++ plugin")
            else
                dlog("[HeadTracking:AIM] Shared memory init failed (non-fatal - Lua overrides still active)")
            end
        end
    else
        dlog("[HeadTracking:AIM] FFI unavailable (" .. tostring(ffi_err) .. ") - skipping shared-memory; CET overrides handle aim decoupling")
    end

    -- Register the CET Override hooks regardless of FFI state.
    if aim_state.override_registered then
        print("[HeadTracking:AIM] Override already registered")
        return true
    end

    print("[HeadTracking:AIM] Registering Override for TargetingSystem:GetCrosshairData")

    -- Override GetCrosshairData to modify aim direction
    -- CET Override pattern: OUT params are returned as multiple values from wrappedMethod
    Override("TargetingSystem", "GetCrosshairData",
        function(this, instigator, wrappedMethod)
            -- Call original - OUT params come back as return values
            local pos, fwd = wrappedMethod(instigator)
            discoTap("TargetingSystem:GetCrosshairData", fwd)

            -- Debug logging
            aim_debug_counter = aim_debug_counter + 1
            local should_log = false  -- silenced; was: (aim_debug_counter % AIM_DEBUG_INTERVAL == 1)

            if should_log then
                print("[HeadTracking:AIM] GetCrosshairData OVERRIDE called!")
                if fwd then
                    print(string.format("[HeadTracking:AIM] Original fwd: x=%.3f y=%.3f z=%.3f", fwd.x, fwd.y, fwd.z))
                else
                    print("[HeadTracking:AIM] Forward is nil!")
                end
                print(string.format("[HeadTracking:AIM] State: enabled=%s yaw=%.2f pitch=%.2f",
                    tostring(aim_state.enabled), aim_state.smooth_yaw, aim_state.smooth_pitch))
            end

            -- If disabled or no forward vector, return original
            if not aim_state.enabled or not fwd then
                return pos, fwd
            end

            -- Check for significant rotation
            local yaw = aim_state.smooth_yaw
            local pitch = aim_state.smooth_pitch

            if math_abs(yaw) < 0.1 and math_abs(pitch) < 0.1 then
                return pos, fwd
            end

            -- Rotate forward vector by INVERSE of head rotation
            -- This compensates for the camera rotation, making bullets land at original aim point
            local compensated = rotateVectorByAngles(fwd, -yaw, -pitch)

            if should_log then
                print(string.format("[HeadTracking:AIM] Compensating aim: yaw=%.2f pitch=%.2f", yaw, pitch))
                print(string.format("[HeadTracking:AIM] Original forward: x=%.3f y=%.3f z=%.3f",
                    fwd.x, fwd.y, fwd.z))
                print(string.format("[HeadTracking:AIM] Compensated forward: x=%.3f y=%.3f z=%.3f",
                    compensated.x, compensated.y, compensated.z))
            end

            return pos, compensated
        end
    )

    print("[HeadTracking:AIM] GetCrosshairData Override registered")

    -- Also override GetBestComponentOnTargetObject which is called during targeting
    -- This function takes shootStartForward as input and may affect bullet trajectory
    print("[HeadTracking:AIM] Registering Override for TargetingSystem:GetBestComponentOnTargetObject")
    Override("TargetingSystem", "GetBestComponentOnTargetObject",
        function(this, shootStartPosition, shootStartForward, target, componentFilter, wrappedMethod)
            discoTap("TargetingSystem:GetBestComponentOnTargetObject", shootStartForward)
            -- Debug logging (use same counter to avoid spam)
            local should_log = false  -- silenced; was: (aim_debug_counter % AIM_DEBUG_INTERVAL == 1)

            if should_log then
                print("[HeadTracking:AIM] GetBestComponentOnTargetObject OVERRIDE called!")
                if shootStartForward then
                    print(string.format("[HeadTracking:AIM] shootStartForward: x=%.3f y=%.3f z=%.3f",
                        shootStartForward.x, shootStartForward.y, shootStartForward.z))
                end
            end

            -- If disabled or invalid forward, call original unchanged
            if not aim_state.enabled or not shootStartForward then
                return wrappedMethod(shootStartPosition, shootStartForward, target, componentFilter)
            end

            -- Check for significant rotation
            local yaw = aim_state.smooth_yaw
            local pitch = aim_state.smooth_pitch

            if math_abs(yaw) < 0.1 and math_abs(pitch) < 0.1 then
                return wrappedMethod(shootStartPosition, shootStartForward, target, componentFilter)
            end

            -- Rotate the shootStartForward by INVERSE of head rotation
            local compensated = rotateVectorByAngles(shootStartForward, -yaw, -pitch)

            if should_log then
                print(string.format("[HeadTracking:AIM] Compensating shootForward: yaw=%.2f pitch=%.2f", yaw, pitch))
                print(string.format("[HeadTracking:AIM] Compensated shootForward: x=%.3f y=%.3f z=%.3f",
                    compensated.x, compensated.y, compensated.z))
            end

            return wrappedMethod(shootStartPosition, compensated, target, componentFilter)
        end
    )
    print("[HeadTracking:AIM] GetBestComponentOnTargetObject Override registered")

    -- Also try overriding GetDefaultCrosshairData in case that's used for shooting
    print("[HeadTracking:AIM] Registering Override for TargetingSystem:GetDefaultCrosshairData")
    Override("TargetingSystem", "GetDefaultCrosshairData",
        function(this, instigator, wrappedMethod)
            local pos, fwd = wrappedMethod(instigator)
            discoTap("TargetingSystem:GetDefaultCrosshairData", fwd)

            local should_log = false  -- silenced; was: (aim_debug_counter % AIM_DEBUG_INTERVAL == 1)
            if should_log then
                print("[HeadTracking:AIM] GetDefaultCrosshairData OVERRIDE called!")
            end

            if not aim_state.enabled or not fwd then
                return pos, fwd
            end

            local yaw = aim_state.smooth_yaw
            local pitch = aim_state.smooth_pitch

            if math_abs(yaw) < 0.1 and math_abs(pitch) < 0.1 then
                return pos, fwd
            end

            local compensated = rotateVectorByAngles(fwd, -yaw, -pitch)
            return pos, compensated
        end
    )
    print("[HeadTracking:AIM] GetDefaultCrosshairData Override registered")

    -- Try overriding camera GetForward - this might be what the game queries for bullet direction
    print("[HeadTracking:AIM] Registering Override for FPPCameraComponent:GetForward")
    local fpp_override_ok = pcall(function()
        Override("FPPCameraComponent", "GetForward",
            function(this, wrappedMethod)
                local fwd = wrappedMethod()
                discoTap("FPPCameraComponent:GetForward", fwd)

                local should_log = false  -- silenced; was: (aim_debug_counter % AIM_DEBUG_INTERVAL == 1)
                if should_log then
                    print("[HeadTracking:AIM] FPPCameraComponent:GetForward OVERRIDE called!")
                end

                if not aim_state.enabled or not fwd then
                    return fwd
                end

                local yaw = aim_state.smooth_yaw
                local pitch = aim_state.smooth_pitch

                if math_abs(yaw) < 0.1 and math_abs(pitch) < 0.1 then
                    return fwd
                end

                -- Return compensated forward when queried
                local compensated = rotateVectorByAngles(fwd, -yaw, -pitch)
                return compensated
            end
        )
    end)
    if fpp_override_ok then
        print("[HeadTracking:AIM] FPPCameraComponent:GetForward Override registered")
    else
        print("[HeadTracking:AIM] FPPCameraComponent:GetForward Override FAILED (method may not exist)")
    end

    -- Also try entCameraComponent which might be the parent class
    print("[HeadTracking:AIM] Registering Override for entCameraComponent:GetForward")
    local ent_override_ok = pcall(function()
        Override("entCameraComponent", "GetForward",
            function(this, wrappedMethod)
                local fwd = wrappedMethod()
                discoTap("entCameraComponent:GetForward", fwd)

                local should_log = false  -- silenced; was: (aim_debug_counter % AIM_DEBUG_INTERVAL == 1)
                if should_log then
                    print("[HeadTracking:AIM] entCameraComponent:GetForward OVERRIDE called!")
                end

                if not aim_state.enabled or not fwd then
                    return fwd
                end

                local yaw = aim_state.smooth_yaw
                local pitch = aim_state.smooth_pitch

                if math_abs(yaw) < 0.1 and math_abs(pitch) < 0.1 then
                    return fwd
                end

                local compensated = rotateVectorByAngles(fwd, -yaw, -pitch)
                return compensated
            end
        )
    end)
    if ent_override_ok then
        print("[HeadTracking:AIM] entCameraComponent:GetForward Override registered")
    else
        print("[HeadTracking:AIM] entCameraComponent:GetForward Override FAILED (method may not exist)")
    end

    -- NOTE: ShootEvents observer removed - it caused lag and didn't work anyway.
    -- Bullet direction is calculated at native level BEFORE our observer runs.
    -- True aim decoupling requires a RED4ext C++ plugin hooking the bullet spawn.

    -- ======================================================================
    -- HITSCAN DISCOVERY + SAVE/RESTORE pass
    -- ======================================================================
    -- The projectile aim-compensation hook at native +0x28D4B8 catches
    -- projectile-based weapons (SMGs with tracers, shotguns, etc.) but
    -- NOT hitscan weapons like pistols. The clean C++ view-matrix hook
    -- was infeasible (see native/RE_NOTES.md re: thundering-herd pages),
    -- so we do the next-best: intercept scripted weapon-fire methods
    -- via CET Override and do the save/restore camera dance inside them.
    -- During the wrapped method, the camera is set back to its clean
    -- (no-head-rotation) orientation; the game's hitscan raycast reads
    -- the clean cam.forward, then we restore head rotation on exit.
    --
    -- CET Override only works on methods we know the name of, and
    -- Cyberpunk's script surface is large. We log each candidate's
    -- invocation (first 3 per run) so we can confirm which actually
    -- fires during a player shot, then the user tells us which one
    -- landed and we trust it for the save/restore.

    -- Per-method call counter (kept for future discovery rounds).
    local shoot_log_counts = {}
    aim_state._shoot_log_counts = shoot_log_counts

    local function logShootMethod(class_name, method_name, note)
        local k = class_name .. ":" .. method_name
        shoot_log_counts[k] = (shoot_log_counts[k] or 0) + 1
        if shoot_log_counts[k] <= 2 then
            dlog(string.format("[HeadTracking:AIM] SHOOT-DISCOVERY: %s fired (call #%d%s)",
                               k, shoot_log_counts[k], note and (" " .. note) or ""))
        end
    end

    -- ======================================================================
    -- HITSCAN SAVE/RESTORE via PlayerPuppet:OnAction + frame-delay
    -- ======================================================================
    -- Discovery confirmed `PlayerPuppet:OnAction` fires on every input
    -- action (including pistol fire). The scripted OnAction returns
    -- before the native hitscan runs though - a straight save/restore
    -- around OnAction doesn't help because native runs outside our window.
    --
    -- Approach: on a RangedAttack action, save cam.localOrientation and
    -- set it to clean (no head rotation). Do NOT restore inside the
    -- Override. Defer the restore to the NEXT frame's camera.lua tick.
    -- That gives the game a full frame of "clean camera" for its native
    -- hitscan to read. Side effect: one frame of un-head-rotated
    -- rendering when you shoot. A flick if head rotation is large.
    -- Set of action names we've already logged once, so we see every
    -- UNIQUE action the game dispatches (mouse look, sprint, jump, fire, ...)
    -- rather than just the first 2 raw OnAction fires.
    aim_state._seen_action_names = aim_state._seen_action_names or {}
    local seen_action_names = aim_state._seen_action_names

    --- Get a readable action name string from a PlayerAction userdata.
    --- CET-version-tolerant. Tries `Game.NameToString`, then `:AsString()`,
    --- then falls back to pulling the human label out of the `--[[ X --]]`
    --- decorator CET injects into `tostring(CName)` so we don't just get
    --- a hash-only representation that won't compare equal to "RangedAttack".
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

    -- True only on an explicit button-RELEASE action (used to clear the
    -- firing-held latch so the hold-clean stops when fire stops). Distinct
    -- from "not pressed" so hold-progress ticks don't prematurely clear it.
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

    local shot_t0 = nil
    aim_state._shot_t0_ref = function() return shot_t0 end

    pcall(function()
        Observe("PlayerPuppet", "OnAction", function(self, action)
            local action_name = actionHumanName(action)
            if not action_name then return end

            -- Log each UNIQUE action name once (capped to 100 to prevent
            -- runaway log growth if the game emits many names).
            if not seen_action_names[action_name] then
                local count = 0
                for _ in pairs(seen_action_names) do count = count + 1 end
                if count < 100 then
                    seen_action_names[action_name] = true
                    dlog(string.format(
                        "[HeadTracking:AIM] ACTION NAME FIRST-SEEN: %q (distinct count now %d)",
                        action_name, count + 1))
                end
            end
            logShootMethod("PlayerPuppet", "OnAction")

            -- Fire action names we want to trigger save/clean on. Covers
            -- the common candidates; we'll prune once the log confirms
            -- which one actually fires on LMB in combat.
            local is_fire =
                action_name == "RangedAttack" or
                action_name == "Shoot" or
                action_name == "Attack" or
                action_name == "PrimaryFire" or
                action_name == "Fire" or
                action_name == "WeaponFire" or
                action_name == "StartShooting" or
                action_name == "RangedAttackStart"

            if is_fire then
                if not isButtonPressedAction(action) then
                    -- Clear the hold-clean latch on explicit release.
                    if isButtonReleasedAction(action) then
                        aim_state.firing_held = false
                    end
                    return
                end
                -- Fire button pressed: latch firing-held for the per-frame
                -- hold-clean (covers native auto-fire follow-up shots).
                aim_state.firing_held = true

                if aim_state.snap_clean_enabled == false then
                    return
                end

                -- If a SNAP-CLEAN is already pending restore this frame,
                -- skip. cam.localOrientation is already clean from the
                -- previous SNAP-CLEAN this same frame, so the second
                -- click's hitscan reads clean naturally. Without this
                -- guard, the second SNAP-CLEAN reads the already-clean
                -- cam, treats it as the new head-rotated baseline, and
                -- overwrites snap_saved_orientation with that clean
                -- value - losing the original head rotation. Restore
                -- then puts clean back instead of head_rotated, leaving
                -- a quaternion residue that composes into visible roll
                -- under rapid mash + off-center head pose.
                if aim_state.pending_snap_restore then
                    return
                end

                if aim_state.settings:get("decouple_diag_clean_cam") == true then
                    if not aim_state.clean_cam_snap_skip_logged then
                        dlog("[HeadTracking:AIM] SNAP-CLEAN skipped: clean-camera diagnostic active")
                        aim_state.clean_cam_snap_skip_logged = true
                    end
                    return
                end

                local native_hitscan_ready = readHitscanHookActive()
                if not native_hitscan_ready
                   and aim_state.udp and aim_state.udp.isNativeHitscanActive then
                    native_hitscan_ready = aim_state.udp:isNativeHitscanActive()
                end

                if native_hitscan_ready == true then
                    aim_state.native_hitscan_hook_active = true
                    aim_state.native_hitscan_window_publishes =
                        aim_state.native_hitscan_window_publishes + 1
                    local marker_ok = shmPublishShotMarker()
                    if aim_state.native_hitscan_window_publishes <= 8 then
                        dlog(string.format(
                            "[HeadTracking:AIM] SNAP-CLEAN skipped: native hitscan hook active, no camera write marker=%s",
                            tostring(marker_ok)))
                    end
                    return
                end

                local now = os.clock()
                if aim_state.last_snap_clean_at
                   and (now - aim_state.last_snap_clean_at) < SNAP_CLEAN_MIN_INTERVAL_SECONDS then
                    return
                end

                -- Timing: scripted OnAction is a PRE-hook. Native hitscan
                -- runs AFTER our callback returns but still within the
                -- current game tick. If we restore synchronously inside
                -- this callback, hitscan reads the head-rotated cam and
                -- the bullet flies where the head points. So we must
                -- leave the camera CLEAN after this callback returns and
                -- defer the restore by one frame.
                local player = Game and Game.GetPlayer and Game.GetPlayer()
                local cam = player and player:GetFPPCameraComponent()

                -- Gate the SNAP-CLEAN on weapon state. The game dispatches
                -- "RangedAttack" on every LMB press regardless of whether
                -- the player will actually fire a bullet - including punches
                -- (no weapon out), mid-reload, mid-holster, weapon-overheat,
                -- empty mag. Without this gate the camera flicks toward the
                -- reticle on every input intent, even ones that don't
                -- produce a hitscan ray.
                local can_actually_fire = false
                if player then
                    -- 1) Player must have a ranged weapon out and ready.
                    local ok, weapon = pcall(function()
                        return player.GetActiveWeapon and player:GetActiveWeapon()
                    end)
                    if ok and weapon then
                        -- 2) Weapon must be ready (not reloading, not holster
                        --    transition, not overheated). HasAnyAmmo() and
                        --    weapon-can-fire-state checks; methods may not all
                        --    exist on every CET version so wrap each in pcall.
                        local has_ammo = true
                        local ok_ammo, ammo = pcall(function()
                            return weapon.HasAnyAmmo and weapon:HasAnyAmmo()
                        end)
                        if ok_ammo and ammo == false then has_ammo = false end

                        local in_reload = false
                        local ok_rel, reloading = pcall(function()
                            return weapon.IsInReload and weapon:IsInReload()
                        end)
                        if ok_rel and reloading == true then in_reload = true end

                        -- A WeaponObject only really "fires" when it's in
                        -- TriggerMode == SemiAuto/FullAuto AND can fire.
                        -- Fallback: just require ammo + not reloading. That
                        -- covers the punch/reload/holster cases the user
                        -- complained about without needing an ECS-deep
                        -- "is currently shooting" check.
                        can_actually_fire = has_ammo and (not in_reload)
                    end
                end

                if cam and aim_state.head_quat and can_actually_fire
                   and (math_abs(aim_state.smooth_yaw) >= 0.1
                        or math_abs(aim_state.smooth_pitch) >= 0.1) then
                    local saved
                    local ok, got = pcall(_camGetLocalOrientation, cam)
                    if ok and got then saved = got end
                    if saved then
                        local hq = aim_state.head_quat
                        local hq_inv = Quaternion.new(-hq.i, -hq.j, -hq.k, hq.r)
                        local a = saved; local b = hq_inv
                        local clean = Quaternion.new(
                            a.r * b.i + a.i * b.r + a.j * b.k - a.k * b.j,
                            a.r * b.j - a.i * b.k + a.j * b.r + a.k * b.i,
                            a.r * b.k + a.i * b.j - a.j * b.i + a.k * b.r,
                            a.r * b.r - a.i * b.i - a.j * b.j - a.k * b.k
                        )
                        pcall(_camSetLocalOrientation, cam, clean)
                        aim_state.last_snap_clean_at = now
                        aim_state.pending_snap_restore = true
                        aim_state.snap_saved_orientation = saved
                        -- Shared shot-start timestamp for the POSTSHOT
                        -- discovery block. Set via the upvalue closure
                        -- captured above.
                        shot_t0 = os.clock()

                        -- Publish the restore request to native over
                        -- BOTH the TCP control channel and SHM (if FFI
                        -- is up). TCP works regardless of FFI state; SHM
                        -- is lower-latency when available. Native's
                        -- OnUpdate consumes whichever landed first. The
                        -- Lua tickSnapRestore below still runs as a
                        -- safety fallback on the next frame.
                        local shm_ok = shmPublishRestore(saved.i, saved.j, saved.k, saved.r)
                        local tcp_ok = false
                        if aim_state.udp and aim_state.udp.sendRestore then
                            tcp_ok = aim_state.udp:sendRestore(saved.i, saved.j, saved.k, saved.r)
                        end
                        dlog(string.format(
                            "[HeadTracking:AIM] SNAP-CLEAN on %s  (t0=%.3f) publish shm=%s tcp=%s",
                            action_name, shot_t0, tostring(shm_ok), tostring(tcp_ok)))
                    end
                end
            end
        end)
        dlog("[HeadTracking:AIM] PlayerPuppet:OnAction observer registered")
    end)

    -- Exhaustive discovery showed no scripted anchor lands post-hitscan
    -- for a player pistol shot. Every observed pre/post hook fires
    -- before the native hitscan reads the camera:
    --   * OnAction (prefix)           - pre, used for save+clean
    --   * OnAction (postfix)          - still pre (tested, bullets center)
    --   * StatPool Stamina update     - pre (tested, bullets center)
    --   * StatPool WeaponOverheat     - pre (tested, bullets center)
    --   * every other catalogued observer (WeaponObject/Projectile/
    --     TargetingSystem/Crosshair/Telemetry) - never fires during a
    --     player hitscan shot at all.
    -- So the hitscan is dispatched entirely in native code between the
    -- pre-fire scripted side-effects and the frame render. Removing the
    -- one-frame render flash requires a native-layer hook; no Lua path
    -- works here.

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
function Aim:update(yaw, pitch, roll, quat)
    aim_state.smooth_yaw = yaw
    aim_state.smooth_pitch = pitch
    aim_state.smooth_roll = roll or 0
    _disco_yaw = yaw
    _disco_pitch = pitch
    if quat then
        aim_state.head_quat = quat
    end

    updateSharedMemory(yaw, pitch, aim_state.enabled, aim_state.is_ads,
                       aim_state.ads_scale, aim_state.smooth_roll,
                       aim_state.head_quat)
    local native_camera_ready = readCameraHookActive()
    if not native_camera_ready
       and aim_state.udp and aim_state.udp.isNativeCameraHookActive then
        native_camera_ready = aim_state.udp:isNativeCameraHookActive()
    end
    if aim_state.udp and aim_state.udp.setNativeState then
        local propagator_inject = aim_state.settings:get("decouple_diag_clean_cam") == true
        aim_state.udp:setNativeState(yaw, pitch, aim_state.smooth_roll,
                                     aim_state.enabled, aim_state.is_ads,
                                     aim_state.head_quat,
                                     propagator_inject)
    end

    aim_state.native_camera_hook_active = native_camera_ready
    aim_state.native_hitscan_hook_active = readHitscanHookActive()
    if not aim_state.native_hitscan_hook_active
       and aim_state.udp and aim_state.udp.isNativeHitscanActive then
        aim_state.native_hitscan_hook_active = aim_state.udp:isNativeHitscanActive()
    end
end

--- @param active boolean
function Aim:setPropagatorInjectActive(active)
    if not shared_mem.initialized or shared_mem.state == nil then return end
    shared_mem.state.propagator_inject_active = active and 1 or 0
    shared_mem.state.camera_hook_inject = active and true or false
end

--- Enable or disable aim compensation.
--- Called every frame from init.lua's onUpdate (with `true` while tracking is
--- allowed, `false` while blocked). Aim:update has already pushed the live
--- pose into shared memory; if `enabled` is unchanged from last frame we
--- don't need to re-write the whole SHM struct - just early-return.
--- When the value DOES change we write the entire struct so the native
--- side picks up the new gate within one frame.
--- @param enabled boolean Whether aim compensation should be active
function Aim:setEnabled(enabled)
    if aim_state.enabled == enabled then
        return  -- no-op fast path: avoids ~14 SHM field writes per frame
    end
    aim_state.enabled = enabled
    updateSharedMemory(aim_state.smooth_yaw, aim_state.smooth_pitch, enabled,
                       aim_state.is_ads, aim_state.ads_scale,
                       aim_state.smooth_roll, aim_state.head_quat)
end

--- Set ADS (Aiming Down Sights) state
--- @param is_ads boolean Whether currently aiming down sights
--- @param scale number|nil ADS effect multiplier (default 0.2 = 20%)
function Aim:setADS(is_ads, scale)
    aim_state.is_ads = is_ads or false
    if scale then
        aim_state.ads_scale = scale
    end
    updateSharedMemory(aim_state.smooth_yaw, aim_state.smooth_pitch, aim_state.enabled,
                       aim_state.is_ads, aim_state.ads_scale,
                       aim_state.smooth_roll, aim_state.head_quat)
end

--- Restore a save/clean'd camera on the NEXT frame after a shoot
--- action (lets the game's native hitscan raycast read the clean
--- orientation for one frame, then we put head rotation back).
--- Call every frame from init.lua's onUpdate.
---
--- Phase 2 note: the native plugin now ack's SNAP-CLEAN publishes via
--- SHM (restore_ack_seq catches up to restore_req_seq once OnUpdate has
--- consumed the request). When native ack'd AND phase 2b is live, the
--- native side has already written the restore into cam.localOrientation
--- and we can skip this fallback. Until phase 2b lands, native only
--- acks - it does NOT perform the cam write - so we MUST run the
--- fallback regardless. The ack check is left here as a no-op conditional
--- that becomes load-bearing the moment phase 2b drops in.
function Aim:tickSnapRestore()
    if not aim_state.pending_snap_restore then return end

    -- Phase 2b+: the native pre-render hook (CameraHook) fires between
    -- hitscan and render, so when it succeeds ack_seq catches req_seq
    -- in the same frame. In that case we skip this fallback entirely -
    -- native has already written head-rotated back into cam.localOrientation
    -- before the frame rendered, killing the one-frame flash.
    --
    -- If native failed for any reason (CRTTI chain not resolved, engine
    -- fault caught by SEH, hook not attached) ack_seq lags and we run
    -- the fallback - cam recovers on the next frame same as phase 2a.
    local NATIVE_PERFORMS_RESTORE = true
    if NATIVE_PERFORMS_RESTORE then
        local req, ack = readRestoreReqSeq(), readRestoreAckSeq()
        if req > 0 and ack >= req then
            aim_state.pending_snap_restore = false
            aim_state.snap_saved_orientation = nil
            return
        end
    end

    local saved = aim_state.snap_saved_orientation
    if saved then
        local player = Game and Game.GetPlayer and Game.GetPlayer()
        local cam = player and player:GetFPPCameraComponent()
        if cam then
            pcall(_camSetLocalOrientation, cam, saved)
        end
    end
    aim_state.pending_snap_restore = false
    aim_state.snap_saved_orientation = nil
end

--- Per-frame hold-clean. Called from onUpdate AFTER camera:apply (so it is
--- not overwritten by the head-rotated view write). While the fire button is
--- held and the weapon can fire, peel the head rotation off cam.localOrientation
--- so the native auto-fire loop's per-shot reads see the mouse-only direction.
--- This is what extends decoupling past the first shot of an automatic burst,
--- IF those follow-up shots read cam+0xD0. The view de-tracks during the burst.
function Aim:tickHoldClean()
    if not aim_state.hold_clean_while_firing then return end
    if not aim_state.firing_held then return end
    if aim_state.snap_clean_enabled == false then return end
    if math_abs(aim_state.smooth_yaw) < 0.1 and math_abs(aim_state.smooth_pitch) < 0.1 then
        return
    end

    local player = Game and Game.GetPlayer and Game.GetPlayer()
    if not player then return end
    local cam = player:GetFPPCameraComponent()
    if not cam then return end

    -- Same can-fire gate as SNAP-CLEAN: weapon out, has ammo, not reloading.
    local ok_w, weapon = pcall(function()
        return player.GetActiveWeapon and player:GetActiveWeapon()
    end)
    if not ok_w or not weapon then
        aim_state.firing_held = false
        return
    end
    local ok_ammo, ammo = pcall(function()
        return weapon.HasAnyAmmo and weapon:HasAnyAmmo()
    end)
    if ok_ammo and ammo == false then return end
    local ok_rel, reloading = pcall(function()
        return weapon.IsInReload and weapon:IsInReload()
    end)
    if ok_rel and reloading == true then return end

    local ok, saved = pcall(_camGetLocalOrientation, cam)
    if not ok or not saved then return end

    -- cam currently holds clean_local * head_quat (camera:apply just wrote it).
    -- Peel: clean = saved * inv(head_quat). inv = (-i,-j,-k, r).
    local hq = aim_state.head_quat
    local hq_inv = Quaternion.new(-hq.i, -hq.j, -hq.k, hq.r)
    local a, b = saved, hq_inv
    local clean = Quaternion.new(
        a.r * b.i + a.i * b.r + a.j * b.k - a.k * b.j,
        a.r * b.j - a.i * b.k + a.j * b.r + a.k * b.i,
        a.r * b.k + a.i * b.j - a.j * b.i + a.k * b.r,
        a.r * b.r - a.i * b.i - a.j * b.j - a.k * b.k
    )
    pcall(_camSetLocalOrientation, cam, clean)
end

function Aim:setHoldCleanWhileFiring(enabled)
    aim_state.hold_clean_while_firing = enabled and true or false
    if not aim_state.hold_clean_while_firing then aim_state.firing_held = false end
    return aim_state.hold_clean_while_firing
end

function Aim:isHoldCleanWhileFiring()
    return aim_state.hold_clean_while_firing ~= false
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

--- Whether the native C++ view-matrix hook is attached AND firing.
--- When true, modules/camera.lua stops writing to cam:SetLocalOrientation
--- because the C++ hook is injecting head rotation at render time, keeping
--- game-logic camera state clean. Polled from shared memory in update().
--- @return boolean active
function Aim:nativeCameraHookActive()
    return aim_state.native_camera_hook_active == true
end

--- Read the native Running::OnUpdate frame counter for diagnostics.
--- @return number
function Aim:nativeRunningFrame()
    return readNativeRunningFrame()
end

--- Read the native-side SNAP-CLEAN req/ack pair. When req == ack, the
--- native OnUpdate has already consumed our latest publish; the fallback
--- Aim:tickSnapRestore can skip this frame (phase 2b will actually do
--- the restore in native, making the Lua fallback redundant).
--- @return number req, number ack
function Aim:restoreSeqs()
    return readRestoreReqSeq(), readRestoreAckSeq()
end

--- Plug in the UDP/TCP tracking input so we can publish SNAP-CLEAN
--- restore requests to native over the TCP control channel. Called from
--- init.lua after both Aim and UDP are initialised. The reference is
--- stored as an upvalue of the module, not captured per-call, because
--- the OnAction observer closure lives for the whole mod lifetime.
--- @param udp table|nil TrackingInput instance (or nil to clear)
function Aim:setUdp(udp)
    aim_state.udp = udp
end

--- Toggle the native FreezeFrameHook's snap-cover blit. Set false to make
--- the SNAP-CLEAN snap visible (e.g. for blog/demo video capture). Backbuffer
--- copy keeps running so re-enabling is seamless. No-op without SHM.
--- @param enabled boolean
function Aim:setFreezeFrameEnabled(enabled)
    if not shared_mem.initialized or shared_mem.state == nil then return end
    shared_mem.state.freeze_frame_enabled = enabled and 1 or 0
end

function Aim:isFreezeFrameEnabled()
    if not shared_mem.initialized or shared_mem.state == nil then return true end
    return (tonumber(shared_mem.state.freeze_frame_enabled) or 1) ~= 0
end

function Aim:setSnapCleanEnabled(enabled)
    aim_state.snap_clean_enabled = enabled and true or false
    if not aim_state.snap_clean_enabled then
        aim_state.pending_snap_restore = false
        aim_state.snap_saved_orientation = nil
    end
end

function Aim:isSnapCleanEnabled()
    return aim_state.snap_clean_enabled ~= false
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

--- Shutdown and cleanup
function Aim:shutdown()
    shutdownSharedMemory()
    aim_state.shared_mem_initialized = false
end

--- Check if aim compensation is enabled
--- @return boolean enabled
function Aim:isEnabled()
    return aim_state.enabled
end

--- Get the current state for debugging
--- @return table state {enabled, is_ads, ads_scale, smooth_yaw, smooth_pitch, override_registered, shared_mem_initialized, shared_mem_frame}
function Aim:getState()
    return {
        enabled = aim_state.enabled,
        is_ads = aim_state.is_ads,
        ads_scale = aim_state.ads_scale,
        smooth_yaw = aim_state.smooth_yaw,
        smooth_pitch = aim_state.smooth_pitch,
        override_registered = aim_state.override_registered,
        shared_mem_initialized = aim_state.shared_mem_initialized,
        shared_mem_frame = shared_mem.frame_counter
    }
end

return Aim
