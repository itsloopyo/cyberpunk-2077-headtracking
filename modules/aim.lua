-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
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


                /* === Section 7: Lua -> native (cam-propagator decouple gate) === */
                uint32_t propagator_inject_active;
                uint32_t propagator_hook_fires;


                /* === Section 9: aim-provider decouple === */
                uint32_t provider_hook_active;
                uint32_t provider_mode;
                uint32_t provider_calls;
                uint32_t provider_overrides;

                /* === Section 10: aim-getter decouple === */
                uint32_t aim_getter_mode;
                uint32_t aim_getter_calls_a;
                uint32_t aim_getter_calls_b;
                uint32_t aim_getter_calls_c;
                uint32_t aim_getter_overrides;
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

    -- The cdef above and native/src/SharedState.hpp describe the same bytes.
    -- The native side pins its layout with a static_assert; this is the other
    -- half of that contract. MapViewOfFile below maps the WHOLE section, so a
    -- drifted cdef does not fail loudly - it silently reads and writes the
    -- wrong offsets, and a larger struct runs off the end of the mapping.
    local EXPECTED_STATE_SIZE = 184
    local actual_size = ffi.sizeof("HeadTrackingState")
    if actual_size ~= EXPECTED_STATE_SIZE then
        -- Clear the module handle so the `if ffi then return true end`
        -- fast path above cannot hand a later caller a success it never got.
        ffi = nil
        return false, string.format(
            "HeadTrackingState layout mismatch: Lua cdef is %d bytes, native expects %d. " ..
            "modules/aim.lua and native/src/SharedState.hpp are out of sync.",
            actual_size, EXPECTED_STATE_SIZE)
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


    shared_mem.state.propagator_inject_active = 0
    shared_mem.state.propagator_hook_fires = 0


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
local function updateSharedMemory(yaw, pitch, enabled, is_ads, ads_scale, roll, quat)
    if not shared_mem.initialized or shared_mem.state == nil then
        return
    end

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
    clean_cam_snap_skip_logged = false,
    settings = nil,
    -- UDP/TCP tracking input. Set via Aim:setUdp() from init.lua so the
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

--- Below this many degrees on BOTH axes the head is effectively centred, and
--- rotating the aim vector would only add float noise to a direction the game
--- is about to use for a raycast. Skipping the work also leaves the vanilla
--- vector object untouched on the overwhelmingly common centred-head frames.
local AIM_COMPENSATION_MIN_DEGREES = 0.1

--- Rotate an engine-supplied forward vector by the INVERSE of the current head
--- rotation, so the game's aim/raycast keeps pointing where the mouse points
--- while the view follows the head.
---
--- Returns the input UNCHANGED (same object) when tracking is off, the vector
--- is missing, or the head is within the deadzone - callers rely on that to
--- hand the engine its original vector back untouched.
--- @param fwd table|nil Vector4 forward direction from the engine.
--- @return table|nil Compensated direction, or `fwd` as-is.
local function compensateForward(fwd)
    if not aim_state.enabled or not fwd then
        return fwd
    end

    local yaw = aim_state.smooth_yaw
    local pitch = aim_state.smooth_pitch
    if math_abs(yaw) < AIM_COMPENSATION_MIN_DEGREES
       and math_abs(pitch) < AIM_COMPENSATION_MIN_DEGREES then
        return fwd
    end

    return rotateVectorByAngles(fwd, -yaw, -pitch)
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
            return pos, compensateForward(fwd)
        end
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
        function(this, instigator, wrappedMethod)
            local pos, fwd = wrappedMethod(instigator)
            discoTap("TargetingSystem:GetDefaultCrosshairData", fwd)
            return pos, compensateForward(fwd)
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
                return compensateForward(fwd)
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
                return compensateForward(fwd)
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


--- Plug in the UDP/TCP tracking input used for the native control channel.
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
