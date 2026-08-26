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
local ShiftCompat = safeRequire("modules/shift_compat")

-- Mod log: the CET console plus the native plugin's HeadTracking.log, which
-- sits next to the game EXE. A "no head tracking" report has to be answerable
-- from that one file, and the most common answer is a CET-side init failure
-- that used to be visible only in CET's own scripting.log. The native function
-- is registered when the game builds its RTTI registry, long before onInit, so
-- a missing one means the plugin is not loaded at all - udp.lua's init says so
-- with a proper message, and until then the console still has the line.
local function mlog(msg)
    print(msg)
    -- pcall because this crosses into the native RTTI dispatcher, and an error
    -- raised there escapes to CET's panic path, which abort()s the process. The
    -- line has already reached the console by this point, so swallowing the
    -- failure loses nothing a reader needs; the native side logs why it could
    -- not register the function.
    if type(Game.HeadTrackingLog) == "function" then
        pcall(Game.HeadTrackingLog, msg)
    end
end

-- Verbose diagnostic stream. Muted unless DebugLog is switched on for an
-- investigative session; goes to the mod folder, not to HeadTracking.log.
local function dlog(msg)
    if DebugLog and DebugLog.write then DebugLog.write(msg) end
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

-- The smart-weapon bracket probe appends and is armed from the console, so
-- without this its file was the one that carried over between sessions.
local function _truncateSmartProbe()
    if not BuiltinCrosshair or not BuiltinCrosshair.SMART_PROBE_PATH then return end
    local f = io.open(BuiltinCrosshair.SMART_PROBE_PATH, "w")
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
    mlog("[HeadTracking] CAUGHT error in " .. tostring(name) .. ": " .. msg)
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
-- The full init diagnostic repeats on the console but reaches HeadTracking.log
-- exactly once per session; see the emit site.
local init_diag_logged = false
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
-- Which camera the head rotation went to last frame. The transition between
-- them is what needs handling: the FPP path leaves a rotation baked into
-- cam.localOrientation and has to peel it back out before standing down.
local was_chase_camera = false

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
        mlog("[HeadTracking:INIT] FAILED at step '" .. name .. "': " .. init_failure_error)
    end
end

registerForEvent("onInit", function()
    if DebugLog and DebugLog.init then pcall(DebugLog.init) end
    _truncateCrashTrace()
    _truncateYawDiag()
    _truncateSmartProbe()
    mlog("[HeadTracking] Initializing...")

    if #require_errors > 0 then
        for _, e in ipairs(require_errors) do
            mlog("[HeadTracking:INIT] " .. e)
        end
        init_failure_step = "module-load"
        init_failure_error = require_errors[1]
        mlog("[HeadTracking:INIT] Aborting init - fix the module load errors above.")
        return
    end

    runInitStep("settings", function()
        settings = Settings.new()
        local loaded = settings:load()
        mlog(loaded and "[HeadTracking] Settings loaded from config.json"
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
            mlog("[HeadTracking:Hotkeys] sanity check errored (non-fatal): " .. tostring(err))
        end
    end

    runInitStep("udp", function()
        udp = UDP.new()
        udp:init()
    end)

    runInitStep("camera", function()
        camera = Camera.new(settings)
        mlog("[HeadTracking] Camera controller initialized")
    end)

    runInitStep("state", function()
        state = State.new()
        state:init(camera, settings)
        mlog("[HeadTracking] State tracker initialized")
    end)

    runInitStep("ui", function()
        ui = UI.new()
        ui:setState(state)
        mlog("[HeadTracking] UI initialized")
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
            mlog("[HeadTracking] Aim->UDP bridge wired")
        end
        mlog("[HeadTracking] Aim compensation initialized")
    end)

    runInitStep("perf", function()
        perf = Perf.new()
        mlog("[HeadTracking] Performance monitor initialized")
    end)

    runInitStep("pose_interp", function()
        if not PoseInterpolator then
            error("PoseInterpolator module failed to load")
        end
        pose_interp = PoseInterpolator.new()
        mlog("[HeadTracking] Pose interpolator initialized")
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
            mlog("[HeadTracking] Native Settings UI integration enabled")
        end
    end)

    -- Crosshair driver runs LAST and absorbs its own failures. If anything
    -- in the built-in reticle hookup throws, head tracking must keep working.
    do
        local ok, err = pcall(function()
            crosshair = BuiltinCrosshair.new(settings, camera)
        end)
        if ok then
            mlog("[HeadTracking] Built-in crosshair driver initialized")
        else
            crosshair = nil
            mlog("[HeadTracking] Built-in crosshair driver FAILED (non-fatal): " .. tostring(err))
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
            mlog("[HeadTracking] ADS aim marker initialized")
        else
            ads_reticle = nil
            mlog("[HeadTracking] ADS aim marker FAILED (non-fatal): " .. tostring(err))
        end
    end

    if init_failure_error then
        mlog("[HeadTracking] Initialization ABORTED - see step '" .. tostring(init_failure_step) .. "' error above")
        return
    end

    -- Reads the master, not `enabled` alone: a player in position-only mode is
    -- tracking and should get the same toast.
    if settings:isTrackingEnabled() then
        ui:showSuccess("Head Tracking: Ready", 3.0)
    end

    mlog("[HeadTracking] Initialization complete")
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

    if not state or not udp or not camera or not aim or not pose_interp or not ads_pose
            or not ShiftCompat then
        if (init_debug_frame % INIT_DEBUG_INTERVAL) == 1 then
            -- This block is the answer to most "no head tracking" reports, so
            -- the first pass goes to HeadTracking.log. It repeats on an
            -- interval for the console (where it scrolls away); repeating it
            -- into the file would be the same paragraph every few seconds for
            -- as long as the session lasts.
            local out = init_diag_logged and dlog or mlog
            init_diag_logged = true
            out("[HeadTracking:INIT] ===== init not complete; full diagnostic =====")
            for i = 1, #require_errors do
                out("[HeadTracking:INIT]   require_err[" .. i .. "]: " .. tostring(require_errors[i]))
            end
            if init_failure_error then
                out("[HeadTracking:INIT]   init failed at step '" .. tostring(init_failure_step) ..
                    "': " .. tostring(init_failure_error))
            end
            out("[HeadTracking:INIT]   modules: state=" .. tostring(state ~= nil) ..
                " udp=" .. tostring(udp ~= nil) ..
                " camera=" .. tostring(camera ~= nil) ..
                " aim=" .. tostring(aim ~= nil) ..
                " pose_interp=" .. tostring(pose_interp ~= nil) ..
                " ads_pose=" .. tostring(ads_pose ~= nil) ..
                " shift_compat=" .. tostring(ShiftCompat ~= nil))
            out("[HeadTracking:INIT] =================================================")
        end
        return
    end

    ads_marker_active = false

    perf:frameStart()

    -- One-shot startup reset: clears any residual rotation in cam.localOrientation
    -- the first frame the FPP cam exists, even before the tracker connects.
    if camera and camera.tryInitialReset then camera:tryInitialReset() end

    -- Shift writes the same camera slot we do and its handler runs after ours,
    -- so while it has an offset configured it overwrites head tracking every
    -- frame. Ask it to stand its camera sources down for as long as tracking is
    -- on. Cheap: this is a no-op once the state matches, and Shift is looked up
    -- at most every couple of seconds until found.
    ShiftCompat.apply(settings:get("enabled") or settings:get("position_enabled"), mlog)

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

    -- Third-person driving renders from the vehicle chase camera, which ignores
    -- everything written to the player's FPP camera. So the head rotation goes
    -- out through the native ViewBuilder hook instead, and the Lua camera path
    -- stands down for as long as that camera is up.
    local chase_camera = tracking_allowed and state:isChaseCameraActive()
        and settings:get("chase_camera_tracking") == true
    udp:setChaseCamera(chase_camera)
    if chase_camera ~= was_chase_camera then
        if chase_camera then
            -- Leaving the FPP path with a rotation still baked into
            -- cam.localOrientation would strand it there for the whole drive,
            -- and it would still be there on dismount.
            camera:suspend()
        end
        was_chase_camera = chase_camera
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
            if chase_camera then
                camera:applyChaseCam(pose_yaw, pose_pitch, pose_roll, deltaTime)
            else
                camera:apply(pose_yaw, pose_pitch, pose_roll, deltaTime, nil, skip_cam_write)
            end
        end
        -- Both cameras get 6DOF, by different routes: the FPP camera takes a
        -- localPosition write, the chase camera ignores that the same way it
        -- ignores localOrientation, so there the offset is published and the
        -- native hook translates the camera's own world position with it.
        if pose_x ~= nil then
            if chase_camera then
                camera:applyChaseCamPosition(pose_x, pose_y, pose_z, deltaTime)
            else
                camera:applyPosition(pose_x, pose_y, pose_z, deltaTime)
            end
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
    local position_x, position_y, position_z = camera:getAppliedPosition()
    local aim_distance, ricochet_hit_valid,
        ricochet_hit_x, ricochet_hit_y, ricochet_hit_z,
        ricochet_normal_x, ricochet_normal_y, ricochet_normal_z,
        ricochet_forward_x, ricochet_forward_y, ricochet_forward_z,
        ricochet_end_x, ricochet_end_y, ricochet_end_z
    if crosshair then
        aim_distance, ricochet_hit_valid,
            ricochet_hit_x, ricochet_hit_y, ricochet_hit_z,
            ricochet_normal_x, ricochet_normal_y, ricochet_normal_z,
            ricochet_forward_x, ricochet_forward_y, ricochet_forward_z,
            ricochet_end_x, ricochet_end_y, ricochet_end_z =
            crosshair:getAimDistance()
    end
    aim:update(rotation.yaw, rotation.pitch, rotation.roll,
               camera:getHeadQuat(),
               position_x, position_y, position_z, aim_distance,
               ricochet_hit_valid,
               ricochet_hit_x, ricochet_hit_y, ricochet_hit_z,
               ricochet_normal_x, ricochet_normal_y, ricochet_normal_z,
               ricochet_forward_x, ricochet_forward_y, ricochet_forward_z,
               ricochet_end_x, ricochet_end_y, ricochet_end_z)
    if aim.summarizeDiscovery then aim:summarizeDiscovery() end

    -- The reticle offset is derived from the head rotation applied to the FPP
    -- camera. In the vehicle chase camera that camera is not what is on screen:
    -- the view is only head-rotated when the native chase injection is actually
    -- running, which needs chase_camera_tracking on. With it off (the shipped
    -- default) the chase view is clean, so compensating the reticle drags it off
    -- the aim point while the camera sits still. Stand the driver down there.
    local view_is_head_tracked = chase_camera or not state:isChaseCameraActive()
    if crosshair then crosshair:tick(view_is_head_tracked) end

    if should_diag then
        local stats = udp:getStats()
        local native_frame = aim.nativeRunningFrame and aim:nativeRunningFrame() or 0
        dlog(string.format(
            "[HeadTracking:DIAG] tracking ON | enabled=%s | shm=%s | fresh=%s | packets=%d | last=%.1fs ago | smoothed yaw=%.1f pitch=%.1f | native_frame=%d | camera=%s",
            tostring(settings:get("enabled")),
            tostring(udp:isReady()),
            tostring(udp:isDataFresh()),
            stats.packet_count,
            udp:secondsSinceLastPacket(),
            rotation.yaw, rotation.pitch,
            native_frame,
            chase_camera and "chase" or "fpp"
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
    mlog("[HeadTracking] Shutting down...")

    -- Give Shift its camera back before we go, or a user who unloads this mod
    -- is left with Shift permanently suppressed for the rest of the session.
    --
    -- Nil-checked where the onUpdate call site is not: this handler runs even
    -- when onInit aborted on a module-load error, which is why every other line
    -- below is guarded the same way. onUpdate needs no guard because the
    -- module-completeness gate at the top of onUpdateImpl lists ShiftCompat and
    -- returns before reaching it.
    if ShiftCompat then
        ShiftCompat.release(mlog)
    end

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

    mlog("[HeadTracking] Shutdown complete")
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
-- Defaults per rule: End / PageUp / PageDown / Insert (nav cluster) with
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
        mlog("[HeadTracking] Enabled")
    else
        if camera then camera:reset() end
        ui:showWarning("Head Tracking: DISABLED", 2.0)
        mlog("[HeadTracking] Disabled")
    end
end
-- End / Ctrl+Shift+Y are polled natively in ScriptChannel.cpp. CET registerHotkey
-- dispatch crashes before entering Lua on this game build, so do not bind End
-- here.

-- PageUp  /  Ctrl+Shift+G - Cycle tracking mode (3-state cycle).
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
    mlog("[HeadTracking] tracking mode -> rot=" .. tostring(next_rot) .. " pos=" .. tostring(next_pos))
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
    mlog("[HeadTracking] yaw_mode -> " .. next_mode)
end
-- PageDown / Ctrl+Shift+H are polled natively in ScriptChannel.cpp. CET registerHotkey
-- dispatch crashes before entering Lua on this game build, so do not bind
-- PageDown here.

-- Insert  /  Ctrl+Shift+U - Cycle what aiming down sights does to the view.
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
    mlog("[HeadTracking] ads_mode -> " .. next_mode)
end
-- Insert / Ctrl+Shift+U are polled natively in ScriptChannel.cpp, same as the
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
    DiagBracketScale      = delegate("crosshair", "setBracketScale",
                                     { announce = "in-car bracket_scale = " }),
    DiagSmartTargets      = delegate("crosshair", "dumpSmartTargets", { noargs = true }),
    DiagSmartScale        = delegate("crosshair", "setSmartScale",
                                     { announce = "smart bracket smart_scale = " }),

    DiagYawMode  = delegate("camera", "probeYawMode"),
    DiagYawBasis = delegate("camera", "diagYawBasis", { noargs = true }),

    DiagShotDiscovery = delegate("aim", "armShotDiscovery"),

}
