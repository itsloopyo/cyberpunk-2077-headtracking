-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- HeadTracking - CET mod entry point
-- Cyberpunk 2077 Head Tracking via OpenTrack UDP protocol
--
-- Features:
-- - 6DOF head tracking via OpenTrack UDP protocol (port 4242)
-- - Context-aware tracking (disables in menus, loading, cutscenes, etc.)
-- - Configurable sensitivity, smoothing, and rotation limits
-- - Visual notifications for state changes
-- - Optional Native Settings UI integration

-- ROOT CAUSE (confirmed 2026-05-22 by PROBE: `type(debug) = nil`): this CET
-- sandbox strips the entire `debug` library. CET's protected-call error handler
-- calls `debug.traceback` on EVERY caught Lua error; with `debug` nil that
-- handler itself throws ("attempt to index a nil value") -> sol logs "error in
-- error handling" and the original error escapes to LuaJIT's panic handler ->
-- abort() -> hard CTD. The crash dumps are exactly this: abort at
-- ucrtbase+0xA4AEE and access-violations inside cyber_engine_tweaks.asi, with NO
-- HeadTrackingAim.dll frame. Net effect: ANY Lua error in our VM is fatal,
-- which is why the reported "call a nil/string/table/number value" varies - it's
-- garbage surfaced by the broken handler, not the real fault.
--
-- Fix: install a minimal global `debug` table with a `traceback` that tolerates
-- both call forms (traceback([thread,] [msg,] [level])). With it present, CET's
-- handler succeeds, so a Lua error becomes a logged-and-survived event (the
-- callback is skipped for that frame) instead of crashing the game. We assign
-- the global unconditionally-if-absent; in a CET mod the bare-name assignment
-- writes to the mod's environment, which is the same environment CET's handler
-- resolves `debug` from.
if type(debug) ~= "table" then
    local function _tb(a, b)
        -- Accept traceback(msg) and traceback(thread, msg, level).
        local m = (type(a) == "string") and a or b
        return (type(m) == "string") and m or ""
    end
    debug = { traceback = _tb, getinfo = function() return {} end }
elseif type(debug.traceback) ~= "function" then
    debug.traceback = function(msg) return tostring(msg or "") end
end

-- Import modules. Each require is pcall-wrapped so we can capture which
-- module file failed to load (vs. a later runtime failure inside onInit).
-- The captured errors are surfaced via the diag loop in case CET console
-- spam scrolls them off.
local require_errors = {}
local function safeRequire(name)
    local ok, mod = pcall(require, name)
    if not ok then
        local err = "require('" .. name .. "') failed: " .. tostring(mod)
        table.insert(require_errors, err)
        print("[HeadTracking:LOAD] " .. err)
        return nil
    end
    if mod == nil then
        local err = "require('" .. name .. "') returned nil (module loaded but did not return a table)"
        table.insert(require_errors, err)
        print("[HeadTracking:LOAD] " .. err)
        return nil
    end
    return mod
end

local UDP = safeRequire("modules/udp")
local Camera = safeRequire("modules/camera")
local Settings = safeRequire("modules/settings")
local State = safeRequire("modules/state")
local UI = safeRequire("modules/ui")
local BuiltinCrosshair = safeRequire("modules/builtin_crosshair")
local AdsReticle = safeRequire("modules/ads_reticle")
local AdsPose = safeRequire("modules/ads_pose")
local Aim = safeRequire("modules/aim")
local NativeSettingsIntegration = safeRequire("modules/nativesettings")
local Perf = safeRequire("modules/perf")
local DebugLog = safeRequire("modules/debuglog")
local Hotkeys = safeRequire("modules/hotkeys")
local PoseInterpolator = safeRequire("modules/poseinterpolator")

-- Convenience: log to both console and file when DebugLog is available,
-- otherwise fall back to plain print so the mod still works if the log
-- module somehow failed to load.
local function dlog(msg)
    if DebugLog and DebugLog.write then
        DebugLog.write(msg)
    else
        print(msg)
    end
end

-- Boundary guard for CET callbacks (onUpdate/onDraw/hotkey handlers).
--
-- An uncaught Lua error inside a CET callback is not a benign "callback
-- disabled" event in this sandbox: CET's protected-call error handler tries to
-- build a traceback via debug.traceback, which is unavailable here (the PROBE
-- lines show _G/ffi stripped), so it fails with "error in error handling" and
-- the error escapes to the Lua panic path, which abort()s the process - a hard
-- crash to desktop. Observed by mashing a hotkey: HeadTracking.log
-- shows "attempt to call a nil value" / "attempt to call a string value" right
-- before the game dies, while the native plugin keeps logging cleanly.
--
-- This is a genuine system boundary (engine <-> our Lua VM), so catching here
-- is correct, not a silent fallback: the handler logs the full error and a
-- best-effort traceback to a flushed crash-trace.log (open->write->close so a
-- subsequent crash can't lose it) AND prints to console. The next repro names
-- the faulting site so the root cause can be fixed; meanwhile a stray error
-- can no longer take the whole game down.
-- Start each launch with an empty crash-trace.log. It is opened append-only at
-- every write so a crash cannot lose the tail, which without this would carry
-- every previous session's errors into the file a user is asked to send. The
-- session that crashed is still recoverable: CET keeps the console output in
-- rotated scripting.N.log generations, and the native plugin keeps its own
-- HeadTrackingAim.prev.log.
local function _truncateCrashTrace()
    local f = io.open("crash-trace.log", "w")
    if f then f:close() end
end

-- Emptied per launch rather than per probe: DiagYawMode and DiagYawBasis are
-- separate console commands that both append here, so truncating when the probe
-- arms would throw away a basis block the user had just captured.
local function _truncateYawDiag()
    local f = io.open("yaw-diag.log", "w")
    if f then f:close() end
end

-- Per-callback log throttle: a per-frame Override that throws would otherwise
-- fsync crash-trace.log 60x/sec. Always log the FIRST occurrence of a given
-- callback name immediately, then at most once every 2s for that name.
local _crashLogLast = {}
local _CRASH_LOG_INTERVAL = 2.0
local function _writeCrash(name, err)
    local msg = tostring(err)
    local now = os.clock()
    local last = _crashLogLast[name]
    if last and (now - last) < _CRASH_LOG_INTERVAL then return end
    _crashLogLast[name] = now

    local tb = msg
    if debug and debug.traceback then
        local ok, t = pcall(debug.traceback, msg, 2)
        if ok and type(t) == "string" then tb = t end
    end
    local f = io.open("crash-trace.log", "a")
    if f then
        f:write(string.format("[%s] CAUGHT in %s: %s\n", os.date("%H:%M:%S"), name, tb))
        f:close()
    end
    print("[HeadTracking] CAUGHT error in " .. tostring(name) .. ": " .. msg)
end

-- Wrap a callback so a throw is contained and logged instead of crashing the
-- game. Creates its closures ONCE at call time (registration), so the returned
-- wrapper allocates nothing per invocation - safe for the per-frame onUpdate /
-- onDraw paths. Forwards a single arg (onUpdate's deltaTime) via an upvalue;
-- LuaJIT's xpcall does not forward extra args itself.
local function guarded(name, fn)
    local arg1
    local function invoke() return fn(arg1) end
    local function onErr(err) _writeCrash(name, err) return err end
    return function(a) arg1 = a; xpcall(invoke, onErr) end
end

-- Hoist closures + reuse the args table so the per-frame Override path
-- (FPPCameraComponent:GetForward, TargetingSystem:GetCrosshairData, etc.)
-- doesn't allocate two closures + a fresh table per call. CET callbacks are
-- non-reentrant on a single wrapper (each Override gets its own closure with
-- its own args upvalue), so reusing the table is safe.
local _unpackFn = table.unpack or unpack
local function guardedVar(name, fn, isOverride)
    local args = {}
    local n = 0
    local function invoke() return fn(_unpackFn(args, 1, n)) end
    local function onErr(err) _writeCrash(name, err); return err end
    return function(...)
        local count = select("#", ...)
        n = count
        for i = 1, count do args[i] = select(i, ...) end

        local ok, a, b, c, d, e = xpcall(invoke, onErr)
        if ok then return a, b, c, d, e end

        if isOverride then
            local wrapped = args[n]
            if type(wrapped) == "function" then
                local wok, wa, wb, wc, wd, we = pcall(wrapped, _unpackFn(args, 2, n - 1))
                if wok then return wa, wb, wc, wd, we end
                _writeCrash(name .. ".wrapped", wa)
            end
        end
    end
end

do
    local rawObserve = Observe
    if type(rawObserve) == "function" then
        Observe = function(class, method, fn)
            return rawObserve(class, method, guardedVar("Observe:" .. tostring(class) .. "." .. tostring(method), fn, false))
        end
    end

    local rawObserveAfter = ObserveAfter
    if type(rawObserveAfter) == "function" then
        ObserveAfter = function(class, method, fn)
            return rawObserveAfter(class, method, guardedVar("ObserveAfter:" .. tostring(class) .. "." .. tostring(method), fn, false))
        end
    end

    local rawOverride = Override
    if type(rawOverride) == "function" then
        Override = function(class, method, fn)
            return rawOverride(class, method, guardedVar("Override:" .. tostring(class) .. "." .. tostring(method), fn, true))
        end
    end
end

-- Module instances (initialized in onInit)
local udp = nil
local camera = nil
local settings = nil
local state = nil
local ui = nil
local crosshair = nil  -- Drives the game's built-in reticle widget so the engine-drawn crosshair marks the true aim point under head tracking
local ads_reticle = nil  -- ImGui aim marker drawn only in ads_mode = "marker", where the game has hidden its own crosshair
local aim = nil  -- Decoupled aim compensation via Override hook
local nativeUI = nil
local perf = nil  -- Optional performance monitoring (low overhead)
local pose_interp = nil  -- Bridges low-rate tracker samples to render rate

-- Debug frame counter for init.lua
local init_debug_frame = 0
local INIT_DEBUG_INTERVAL = 120

-- Periodic diagnostic state. Lines are gated behind DebugLog (off by
-- default; flip via DebugLog.setEnabled(true) from the CET console for
-- investigative sessions). The shipping mod runs silent.
local DIAG_INTERVAL_S = 3.0
local diag_last_log_time = 0
local diag_first_packet_logged = false

-- Captured init failure (re-emitted by the diag loop so the error stays
-- visible even after CET console spam scrolls past).
local init_failure_step = nil
local init_failure_error = nil

-- Hotkey debounce state (key: hotkey id, value: last fire os.clock())
-- 0.3s minimum between fires prevents held-key repeat.
local HOTKEY_DEBOUNCE_SECONDS = 0.3
local hotkey_last_fire = {}

-- Tracks the previous frame's tracking-allowed state so onUpdate can detect
-- the allowed->not-allowed edge itself. camera:reset() (which peels our baked
-- head rotation back off and clears last_head_quat) is otherwise only driven by
-- the GameUI transition listeners in state.lua. Several suppression causes are
-- POLLED, not evented - warmup, the settings-disabled gate, and any GameUI
-- block predicate with no matching Listen() - so they bypass that reset. When
-- one of those suppresses tracking, the engine repositions the camera while
-- last_head_quat stays stale; on resume apply() peels the stale quat against
-- the engine's fresh orientation, baking in a permanent inverse-head rotation
-- (view ends up rolled and off-forward). Resetting on the per-frame edge catches
-- every cause uniformly, while last_head_quat is still validly baked.
local was_tracking_allowed = true

-- Maps the absolute tracker pose to one relative to the pose the sights came up
-- on, for the ads_modes that keep tracking live through the aim. See
-- modules/ads_pose.lua.
local ads_pose = nil

-- Whether onDraw should paint the aim marker this frame. onUpdate owns the
-- decision and onDraw only reads it, so it is cleared at the top of every
-- update - including the paths that return early - rather than left to go
-- stale and paint a marker over a menu.
local ads_marker_active = false

local function hotkeyDebounced(id)
    local now = os.clock()
    local last = hotkey_last_fire[id] or 0
    if (now - last) < HOTKEY_DEBOUNCE_SECONDS then return true end
    hotkey_last_fire[id] = now
    return false
end

-- Hotkey wiring.
-- Both binding sets (nav-cluster keys and the Ctrl+Shift chords) are polled
-- in native/src/ScriptChannel.cpp and delivered as one-shot flags on the pose
-- socket. Neither set can go through CET: registerHotkey dispatch crashes
-- before entering Lua on this game build, and LuaJIT FFI is sandboxed
-- (require "ffi" fails) so Lua-side GetAsyncKeyState polling is impossible.
-- Native ORs each nav key with its chord into one edge source per action, so
-- either key fires the handler exactly once.

-- Forward declarations so the onUpdate dispatch resolves the upvalue at call.
local handleToggleTracking, handleCycleMode,
      handleToggleYawMode

-- Lifecycle: Called when mod initializes.
-- Each step is wrapped so that on failure we capture WHICH step failed and
-- the error message, and the diag loop keeps re-emitting it. Without this
-- the error scrolls off the CET console and we just see "modules not ready"
-- spam with no way to tell why.
local function runInitStep(name, fn)
    if init_failure_error then return end  -- short-circuit after first failure
    local ok, err = pcall(fn)
    if not ok then
        init_failure_step = name
        init_failure_error = tostring(err)
        print("[HeadTracking:INIT] FAILED at step '" .. name .. "': " .. init_failure_error)
    end
end

registerForEvent("onInit", function()
    if DebugLog and DebugLog.init then pcall(DebugLog.init) end
    _truncateCrashTrace()
    _truncateYawDiag()
    dlog("[HeadTracking] Initializing...")

    if #require_errors > 0 then
        for _, e in ipairs(require_errors) do
            print("[HeadTracking:INIT] " .. e)
        end
        init_failure_step = "module-load"
        init_failure_error = require_errors[1]
        print("[HeadTracking:INIT] Aborting init - fix the module load errors above.")
        return
    end

    runInitStep("settings", function()
        settings = Settings.new()
        local loaded = settings:load()
        print(loaded and "[HeadTracking] Settings loaded from config.json"
                      or "[HeadTracking] Created default config.json")
        -- The few things a session starts in regardless of how the last one
        -- ended. Everything else, yaw_mode and ads_mode included, is persisted.
        -- See Settings:applyLaunchState.
        settings:applyLaunchState()
    end)

    -- Seed any of our hotkey actions that aren't bound in CET's bindings.json.
    -- Runs every launch (not just at install time) so a wiped or missing
    -- bindings file heals itself. Never touches bindings the user has
    -- deliberately set. Best-effort: a failure here (file permissions,
    -- malformed JSON, CET dir layout we don't expect) must not abort mod
    -- init, so we absorb the error locally.
    if Hotkeys and Hotkeys.ensure then
        local ok, err = pcall(Hotkeys.ensure)
        if not ok then
            print("[HeadTracking:Hotkeys] sanity check errored (non-fatal): " .. tostring(err))
        end
    end

    runInitStep("udp", function()
        udp = UDP.new()
        udp:init()
    end)

    runInitStep("camera", function()
        camera = Camera.new(settings)
        print("[HeadTracking] Camera controller initialized")
    end)

    runInitStep("state", function()
        state = State.new()
        state:init(camera, settings)
        print("[HeadTracking] State tracker initialized")
    end)

    runInitStep("ui", function()
        ui = UI.new()
        ui:setState(state)
        print("[HeadTracking] UI initialized")
    end)

    runInitStep("aim", function()
        aim = Aim.new(settings, camera)
        aim:init()
        -- Wire the tracking input for the native control channel.
        -- publish restore quats to native over the script control channel.
        -- Must happen after both aim:init() (observer registered) and
        -- the udp init step completed; safe to call even if aim:setUdp
        -- is pre-init because the observer fires later.
        if udp and aim.setUdp then
            aim:setUdp(udp)
            print("[HeadTracking] Aim->UDP bridge wired")
        end
        print("[HeadTracking] Aim compensation initialized")
    end)

    runInitStep("perf", function()
        perf = Perf.new()
        print("[HeadTracking] Performance monitor initialized")
    end)

    runInitStep("pose_interp", function()
        if not PoseInterpolator then
            error("PoseInterpolator module failed to load")
        end
        pose_interp = PoseInterpolator.new()
        print("[HeadTracking] Pose interpolator initialized")
    end)

    runInitStep("ads_pose", function()
        if not AdsPose then
            error("AdsPose module failed to load")
        end
        ads_pose = AdsPose.new()
    end)

    runInitStep("nativeUI", function()
        nativeUI = NativeSettingsIntegration.new(settings)
        nativeUI:setCamera(camera)
        nativeUI:setUI(ui)
        if nativeUI:init() then
            print("[HeadTracking] Native Settings UI integration enabled")
        end
    end)

    -- Crosshair driver runs LAST and absorbs its own failures. If anything
    -- in the built-in reticle hookup throws, head tracking must keep working.
    do
        local ok, err = pcall(function()
            crosshair = BuiltinCrosshair.new(settings, camera)
        end)
        if ok then
            print("[HeadTracking] Built-in crosshair driver initialized")
        else
            crosshair = nil
            print("[HeadTracking] Built-in crosshair driver FAILED (non-fatal): " .. tostring(err))
        end
    end

    -- The aim marker projects through the crosshair driver, so it only exists
    -- if that came up. Without it ads_mode = "marker" still tracks through the
    -- aim, it just draws no marker - which is exactly ads_mode = "tracked".
    if crosshair and AdsReticle then
        local ok, err = pcall(function()
            ads_reticle = AdsReticle.new(crosshair)
        end)
        if ok then
            print("[HeadTracking] ADS aim marker initialized")
        else
            ads_reticle = nil
            print("[HeadTracking] ADS aim marker FAILED (non-fatal): " .. tostring(err))
        end
    end

    if init_failure_error then
        print("[HeadTracking] Initialization ABORTED - see step '" .. tostring(init_failure_step) .. "' error above")
        return
    end

    -- Reads the master, not `enabled` alone: a player in position-only mode is
    -- tracking and should get the same toast.
    if settings:isTrackingEnabled() then
        ui:showSuccess("Head Tracking: Ready", 3.0)
    end

    print("[HeadTracking] Initialization complete")
end)

-- Lifecycle: Called every frame
local function onUpdateImpl(deltaTime)
    init_debug_frame = init_debug_frame + 1

    -- onUpdate can fire once before onInit completes - tolerate that single
    -- race without masking later bugs. After onInit, all modules must exist.
    -- One-shot RTTI dump of the FPP camera component on the first frame
    -- where modules are loaded AND the player exists. Diagnostic only;
    -- writes to HeadTracking-diag.log via dlog. Set _cam_rtti_dumped flag
    -- to nil in the CET console to re-run.
    if not _cam_rtti_dumped and state and udp and camera and aim and Game.GetPlayer() then
        local ok, mod = pcall(require, "dump_cam_rtti")
        if ok and mod and mod.run then
            local ran = mod.run()
            if ran then _cam_rtti_dumped = true end
        else
            dlog("[HeadTracking:INIT] dump_cam_rtti require failed: " .. tostring(mod))
            _cam_rtti_dumped = true
        end
    end

    if not state or not udp or not camera or not aim or not pose_interp or not ads_pose then
        if (init_debug_frame % INIT_DEBUG_INTERVAL) == 1 then
            dlog("[HeadTracking:INIT] ===== init not complete; full diagnostic =====")
            for i = 1, #require_errors do
                dlog("[HeadTracking:INIT]   require_err[" .. i .. "]: " .. tostring(require_errors[i]))
            end
            if init_failure_error then
                dlog("[HeadTracking:INIT]   init failed at step '" .. tostring(init_failure_step) ..
                      "': " .. tostring(init_failure_error))
            end
            dlog("[HeadTracking:INIT]   modules: state=" .. tostring(state ~= nil) ..
                 " udp=" .. tostring(udp ~= nil) ..
                 " camera=" .. tostring(camera ~= nil) ..
                 " aim=" .. tostring(aim ~= nil))
            dlog("[HeadTracking:INIT] =================================================")
        end
        return
    end

    ads_marker_active = false

    perf:frameStart()

    -- One-shot startup reset: clears any residual rotation in cam.localOrientation
    -- the first frame the FPP cam exists, even before the tracker connects.
    if camera and camera.tryInitialReset then camera:tryInitialReset() end

    local now = os.clock()
    local should_diag = (now - diag_last_log_time) >= DIAG_INTERVAL_S

    -- Hotkey edges arrive as one-shot flags latched by the socket callback, so
    -- reading them here (before udp:poll below) loses nothing. This must sit
    -- ABOVE the tracking-allowed gate: with tracking toggled off the gate
    -- closes, and dispatching below it would leave no way to turn tracking
    -- back on.
    if udp:consumeNativeToggleTrackingRequested() then handleToggleTracking() end
    if udp:consumeNativeCycleModeRequested()      then handleCycleMode()      end
    if udp:consumeNativeToggleYawRequested()      then handleToggleYawMode()  end
    if udp:consumeNativeCycleAdsModeRequested()   then handleCycleAdsMode()   end

    local tracking_allowed = state:isTrackingAllowed()
    if was_tracking_allowed and not tracking_allowed then
        -- Falling edge: peel our head rotation off NOW, while last_head_quat is
        -- still the rotation actually baked in the camera. This restores the
        -- clean view for the suppressed period and clears last_head_quat so the
        -- resume frame doesn't peel a stale quat against an engine-reset camera.
        --
        -- ADS suspends rather than resets. It is measured in seconds and
        -- happens many times a firefight, so it must not throw away the
        -- smoothing state: lowering the weapon would swing the view back
        -- through the whole head angle.
        if state:getReason() == State.REASON.ADS then
            camera:suspend()
        else
            camera:reset()
        end
    end
    was_tracking_allowed = tracking_allowed

    -- "marker" and "tracked" keep the gate open through the aim and feed poses
    -- relative to the one the sights came up on, so the entry frame is identity
    -- - the same snap onto the aim point that "paused" gets by standing
    -- tracking down - and head movement after it still moves the view.
    -- "paused" never reaches here: it blocks in state.lua.
    local ads_tracked = tracking_allowed and state:isAdsActive()
    if ads_tracked and settings:get("ads_mode") == "marker" then
        ads_marker_active = ads_reticle ~= nil
    end

    if not tracking_allowed then
        if should_diag then
            dlog(string.format(
                "[HeadTracking:DIAG] tracking BLOCKED reason=%s | enabled=%s | shm=%s | last_packet=%.1fs ago",
                tostring(state:getReason()),
                tostring(settings:get("enabled")),
                tostring(udp:isReady()),
                udp:secondsSinceLastPacket()
            ))
            diag_last_log_time = now
        end
        aim:setEnabled(false)
        -- Keep talking to the native plugin while suppressed. The command
        -- udp:poll() sends is the ONLY channel that reaches the native side -
        -- the CET sandbox strips LuaJIT FFI on this build, so aim.lua's
        -- shared-memory writes never land - and poll() lives below this early
        -- return. Going silent froze the native side on the last state we
        -- published, so its aim hooks kept peeling a head rotation the camera
        -- no longer carried and threw ADS rounds the head angle off target.
        -- Pumping here also keeps hotkey edges arriving during menus, so a
        -- press in one queues for the return to gameplay.
        aim:publishSuppressedState()
        udp:poll()
        if crosshair then crosshair:tick(false) end
        pose_interp:reset()
        ads_pose:reset()
        return
    end

    perf:updateStart()

    -- Poll for the latest tracking sample. The poll returns nil on frames
    -- with no fresh UDP packet, but the interpolator runs every frame:
    -- it bridges the tracker rate (e.g. 60 Hz) to the render rate (e.g.
    -- 120 Hz) by lerping between the last two samples and extrapolating
    -- past the latest. Without this, half of render frames get no new
    -- value and camera:apply gets skipped, leaving visible judder on
    -- high-refresh displays.
    local data = udp:poll()
    -- Re-read connection locality every frame: it picks LocalSmoothing vs
    -- RemoteSmoothing and must follow a tracker swap without a restart.
    camera:setRemoteConnection(udp:isRemoteConnection())
    if data and not diag_first_packet_logged then
        dlog(string.format(
            "[HeadTracking:DIAG] FIRST packet received: yaw=%.2f pitch=%.2f roll=%.2f",
            data.yaw, data.pitch, data.roll))
        diag_first_packet_logged = true
    end

    local raw_yaw, raw_pitch, raw_roll, raw_seq
    if data then
        raw_yaw, raw_pitch, raw_roll, raw_seq = data.yaw, data.pitch, data.roll, data.seq
    end
    local interp_yaw, interp_pitch, interp_roll =
        pose_interp:update(raw_yaw, raw_pitch, raw_roll, raw_seq, deltaTime)

    local raw_x, raw_y, raw_z
    if data then raw_x, raw_y, raw_z = data.x or 0, data.y or 0, data.z or 0 end

    local pose_yaw, pose_pitch, pose_roll, pose_x, pose_y, pose_z =
        ads_pose:update(ads_tracked, interp_yaw, interp_pitch, interp_roll,
                        raw_x, raw_y, raw_z)

    if pose_yaw ~= nil then
        local clean_cam_decouple = settings:get("decouple_diag_clean_cam") == true
        if aim.setPropagatorInjectActive then
            aim:setPropagatorInjectActive(clean_cam_decouple)
        end

        local skip_cam_write = clean_cam_decouple
        local rot_on = settings:get("enabled") and true or false
        if rot_on then
            camera:apply(pose_yaw, pose_pitch, pose_roll, deltaTime, nil, skip_cam_write)
        end
        if pose_x ~= nil then
            camera:applyPosition(pose_x, pose_y, pose_z, deltaTime)
        end
        perf:recordCameraUpdate()
    end

    if data then
        perf:recordPacket()
    end

    -- Order matters: aim:update stages the native push using aim_state.enabled,
    -- so flipping the flag first keeps the resume frame from publishing a live
    -- head rotation still labelled "tracking off".
    aim:setEnabled(true)
    local rotation = camera:getSmoothedRotation()
    aim:update(rotation.yaw, rotation.pitch, rotation.roll,
               camera:getHeadQuat())
    if aim.summarizeDiscovery then aim:summarizeDiscovery() end

    if crosshair then crosshair:tick(true) end

    if should_diag then
        local stats = udp:getStats()
        local native_frame = aim.nativeRunningFrame and aim:nativeRunningFrame() or 0
        dlog(string.format(
            "[HeadTracking:DIAG] tracking ON | enabled=%s | shm=%s | fresh=%s | packets=%d | last=%.1fs ago | smoothed yaw=%.1f pitch=%.1f | native_frame=%d",
            tostring(settings:get("enabled")),
            tostring(udp:isReady()),
            tostring(udp:isDataFresh()),
            stats.packet_count,
            udp:secondsSinceLastPacket(),
            rotation.yaw, rotation.pitch,
            native_frame
        ))
        diag_last_log_time = now
    end

    perf:updateEnd()
end
registerForEvent("onUpdate", guarded("onUpdate", onUpdateImpl))

-- Lifecycle: Called for ImGui rendering
local function onDrawImpl()
    if ui then
        ui:draw()
    end
    if ads_reticle then
        ads_reticle:draw(ads_marker_active)
    end
end
registerForEvent("onDraw", guarded("onDraw", onDrawImpl))

-- Lifecycle: Called on shutdown
registerForEvent("onShutdown", function()
    print("[HeadTracking] Shutting down...")

    -- Shutdown Native Settings integration (unsubscribes from observers)
    if nativeUI then
        nativeUI:shutdown()
    end

    if udp then
        udp:close()
    end

    if settings then
        settings:save()
    end

    print("[HeadTracking] Shutdown complete")
end)

-- Resolve a tri-state console-toggle argument: nil flips the current value,
-- an explicit value coerces to that boolean. Shared by the Diag* console hooks.
local function resolveToggle(current, force)
    if force == nil then return not current end
    return force and true or false
end

-- DIAGNOSTIC: exposed through the returned mod table so the user can flip
-- the clean-cam diag from the CET console while the game is running:
--   GetMod("HeadTracking").DiagCleanCam()      -- toggle on/off
--   GetMod("HeadTracking").DiagCleanCam(true)  -- force on
--   GetMod("HeadTracking").DiagCleanCam(false) -- force off
-- When on, Lua writes CLEAN (mouse-only) quat to cam.localOrientation.
-- View tracking visibly breaks (camera stops following the head); the
-- point is to observe which engine systems STILL track the head (= they
-- don't read cam+0xD0) vs. follow the mouse (= they DO read cam+0xD0).
-- Watch in particular: interaction-prompt direction, click-flick direction.
local function diagCleanCam(force)
    if not settings or not ui then
        print("[HeadTracking:DIAG] settings/ui not initialised; mod still booting?")
        return
    end
    local current = settings:get("decouple_diag_clean_cam")
    if current == nil then current = false end
    local new_val = resolveToggle(current, force)
    settings:set("decouple_diag_clean_cam", new_val)
    local msg = "Clean-cam diag: " .. (new_val and "ON (cam = clean/mouse)" or "OFF (cam = head-tracked)")
    print("[HeadTracking:DIAG] " .. msg)
    if ui then
        if new_val then ui:showWarning(msg, 3.0) else ui:showSuccess(msg, 2.0) end
    end
end

-- Standard CameraUnlock hotkey contract.
-- Defaults per rule: End / PageUp / PageDown / Home (nav cluster) with
-- Ctrl+Shift+{Y,G,H,U} chord alternatives drawn from the T/Y/U/G/H/J cluster.
-- Both sets are polled natively in ScriptChannel.cpp and are NOT rebindable:
-- CET's registerHotkey dispatch crashes before entering Lua on this game
-- build, so none of these can go through the Bindings menu.

-- End  /  Ctrl+Shift+Y - Toggle head tracking
--
-- Master switch: rotation AND position go off together. Position tracking
-- staying live after End reads as the mod ignoring the hotkey.
function handleToggleTracking()
    dlog("[HeadTracking:HOTKEY] ToggleHeadTracking fired")
    if hotkeyDebounced("ToggleHeadTracking") then return end
    if not settings or not ui then return end

    local enabled = not settings:isTrackingEnabled()
    settings:setTrackingEnabled(enabled)

    if state then state:refresh() end

    if enabled then
        ui:showSuccess("Head Tracking: ENABLED", 2.0)
        dlog("[HeadTracking] Enabled")
    else
        if camera then camera:reset() end
        ui:showWarning("Head Tracking: DISABLED", 2.0)
        dlog("[HeadTracking] Disabled")
    end
end
-- End / Ctrl+Shift+Y are polled natively in ScriptChannel.cpp. CET registerHotkey
-- dispatch crashes before entering Lua on this game build, so do not bind End
-- here.

-- PageUp  /  Ctrl+Shift+G - Cycle tracking mode (3-state cycle).
-- 6DOF isn't wired to the Cyberpunk camera yet; the setting flips so the
-- contract is visible, and the user sees a toast that the feature is pending.
-- Canonical CameraUnlock binding is "Cycle tracking mode" (3-state cycle:
-- normal -> rotation-only -> position-only -> normal). Wired here as a
-- binary toggle until 6DOF positional tracking lands.
-- PageUp cycles through the three tracking modes. Order is fixed so the
-- sequence reads naturally from "everything on" toward "off-axes":
--   6DOF  -> 3DOF rotation only -> 3DOF position only -> 6DOF -> ...
function handleCycleMode()
    if hotkeyDebounced("TogglePositionTracking") then return end
    if not settings or not ui then return end

    local rot_on = settings:get("enabled") and true or false
    local pos_on = settings:get("position_enabled") and true or false

    local next_rot, next_pos, label
    if rot_on and pos_on then
        next_rot, next_pos, label = true, false, "Tracking: 3DOF (rotation only)"
    elseif rot_on and not pos_on then
        next_rot, next_pos, label = false, true, "Tracking: 3DOF (position only)"
    else
        -- pos_on/!rot_on (or both-off, which the gate normally prevents)
        next_rot, next_pos, label = true, true, "Tracking: 6DOF (full)"
    end

    settings:set("enabled", next_rot)
    settings:set("position_enabled", next_pos)
    if state then state:refresh() end

    -- When rotation flips off, peel any baked head rotation back out of
    -- cam.localOrientation so we don't leave the player frozen-headed.
    if camera and rot_on and not next_rot then
        camera:reset()
    end

    ui:showSuccess(label, 2.0)
    print("[HeadTracking] tracking mode -> rot=" .. tostring(next_rot) .. " pos=" .. tostring(next_pos))
end
-- PageUp / Ctrl+Shift+G are polled natively in ScriptChannel.cpp. CET registerHotkey
-- dispatch crashes before entering Lua on this game build, so do not bind
-- PageUp here.

-- PageDown - Toggle yaw mode (world <-> local)
function handleToggleYawMode()
    dlog("[HeadTracking:HOTKEY] ToggleYawMode fired")
    if hotkeyDebounced("ToggleYawMode") then return end
    if not settings or not ui then return end

    local current = settings:get("yaw_mode") or "world"
    local next_mode = (current == "world") and "local" or "world"
    settings:set("yaw_mode", next_mode)

    if camera and camera.prepareYawModeSwitch then
        camera:prepareYawModeSwitch()
    end

    local label = (next_mode == "world")
        and "Yaw Mode: WORLD (horizon-locked)"
        or  "Yaw Mode: LOCAL (camera-relative)"
    ui:showSuccess(label, 2.0)
    print("[HeadTracking] yaw_mode -> " .. next_mode)
end
-- PageDown / Ctrl+Shift+H are polled natively in ScriptChannel.cpp. CET registerHotkey
-- dispatch crashes before entering Lua on this game build, so do not bind
-- PageDown here.

-- Home  /  Ctrl+Shift+U - Cycle what aiming down sights does to the view.
-- U is the next free letter in the T/Y/U/G/H/J cluster after Y, G and H.
-- Ctrl+Shift+T is deliberately skipped: it was the recenter chord before mods
-- stopped keeping a centre, so it would still fire on muscle memory.
local ADS_MODE_CYCLE = { "paused", "marker", "tracked" }
local ADS_MODE_LABELS = {
    paused  = "ADS: tracking paused",
    marker  = "ADS: tracking on, aim marker shown",
    tracked = "ADS: tracking on, no aim marker",
}

function handleCycleAdsMode()
    dlog("[HeadTracking:HOTKEY] CycleAdsMode fired")
    if hotkeyDebounced("CycleAdsMode") then return end
    if not settings or not ui then return end

    local current = settings:get("ads_mode") or "paused"
    local next_mode = ADS_MODE_CYCLE[1]
    for i, mode in ipairs(ADS_MODE_CYCLE) do
        if mode == current then
            next_mode = ADS_MODE_CYCLE[(i % #ADS_MODE_CYCLE) + 1]
            break
        end
    end

    settings:set("ads_mode", next_mode)
    -- The gate branches on this setting, so a change mid-aim has to re-run the
    -- walk rather than ride the cached verdict until its TTL expires.
    if state then state:refresh() end

    ui:showSuccess(ADS_MODE_LABELS[next_mode], 2.5)
    print("[HeadTracking] ads_mode -> " .. next_mode)
end
-- Home / Ctrl+Shift+U are polled natively in ScriptChannel.cpp, same as the
-- other three.

-- Public API for the CET console. Reachable as
--   GetMod("HeadTracking").DiagCleanCam(true)
-- CET sandboxes each mod's own globals, so file-scope `function Foo() ...`
-- does NOT become a console global; the return table is the only way
-- through.
local function diagVerbose(force)
    if not DebugLog or not DebugLog.setEnabled then
        print("[HeadTracking:DIAG] DebugLog module unavailable")
        return
    end
    local current = DebugLog.isEnabled and DebugLog.isEnabled() or false
    local new_val = resolveToggle(current, force)
    DebugLog.setEnabled(new_val)
    print("[HeadTracking:DIAG] Verbose console logging: " .. (new_val and "ON" or "OFF"))
end



-- Console delegates.
--
-- Most Diag* entries are the same shape: forward one argument to a method on
-- one of the runtime drivers, or explain that the driver isn't up yet. The
-- drivers are assigned in onInit, so each accessor is resolved at CALL time,
-- not while this table is being built.
local DRIVERS = {
    crosshair = { get = function() return crosshair end, label = "crosshair" },
    camera    = { get = function() return camera end,    label = "camera" },
    aim       = { get = function() return aim end,       label = "aim" },
}

local function toBool(v) return v and true or false end

--- Build a console entry forwarding one argument to driver:method(arg).
--- @param driver_name string Key into DRIVERS.
--- @param method string Method name looked up on the driver at call time.
--- @param opts table|nil
---   coerce   function  Applied to the argument before forwarding.
---   announce string    Printed with the call's return value appended.
---   silent   boolean   Missing driver/method is a no-op instead of a log line.
---   noargs   boolean   Target takes no parameter; call it with none. Lua would
---                      discard a surplus argument anyway, but stating it here
---                      keeps a console typo from becoming a real argument if
---                      the target ever grows an optional parameter.
--- @return function Console-callable delegate.
local function delegate(driver_name, method, opts)
    opts = opts or {}
    local driver = DRIVERS[driver_name]
    return function(arg)
        local d = driver.get()
        if not (d and d[method]) then
            if not opts.silent then
                print("[HeadTracking:DIAG] " .. driver.label .. " driver not available")
            end
            return
        end
        local result
        if opts.noargs then
            result = d[method](d)
        else
            local value = arg
            if opts.coerce then value = opts.coerce(arg) end
            result = d[method](d, value)
        end
        if opts.announce then
            print("[HeadTracking:DIAG] " .. opts.announce .. tostring(result))
        end
    end
end

return {
    DiagCleanCam    = diagCleanCam,
    DiagVerbose     = diagVerbose,

    -- These two predate the "driver not available" convention and stay silent
    -- when the crosshair driver is absent. Kept as-is so console scripts that
    -- call them in a loop don't start spamming.
    DiagReticle   = delegate("crosshair", "dumpStatus",   { silent = true, noargs = true }),
    DiagDumpTrees = delegate("crosshair", "dumpAllTrees", { silent = true, noargs = true }),

    DiagNameplateProbe    = delegate("crosshair", "probeNameplates"),
    DiagNameplateAnchor   = delegate("crosshair", "probeNameplateAnchor", { noargs = true }),
    DiagNameplateHide     = delegate("crosshair", "setNameplatesHidden",  { coerce = toBool }),
    DiagCrosshairSuppress = delegate("crosshair", "setCrosshairSuppress", { coerce = toBool }),
    DiagShoveHitMarker    = delegate("crosshair", "setShoveHitMarker",    { coerce = toBool }),
    DiagShoveNameplate    = delegate("crosshair", "setShoveNameplate",    { coerce = toBool }),
    DiagCrosshairTree     = delegate("crosshair", "dumpCrosshairTree", { noargs = true }),
    DiagCrosshairMotion   = delegate("crosshair", "probeCrosshairMotion"),
    DiagGate              = delegate("crosshair", "probeGate"),
    DiagLockSignal        = delegate("crosshair", "probeLockSignal"),
    DiagShoveOnly         = delegate("crosshair", "setShoveOnly"),
    DiagHitMarker         = delegate("crosshair", "probeHitMarker"),
    DiagReticleFov        = delegate("crosshair", "probeReticleFov"),
    DiagBracketScale      = delegate("crosshair", "setBracketScale",
                                     { announce = "in-car bracket_scale = " }),

    DiagYawMode  = delegate("camera", "probeYawMode"),
    DiagYawBasis = delegate("camera", "diagYawBasis", { noargs = true }),

    DiagShotDiscovery = delegate("aim", "armShotDiscovery"),

}
