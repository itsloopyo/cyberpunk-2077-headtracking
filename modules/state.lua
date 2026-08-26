-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- State Management Module
-- Handles game state detection and tracking enable/disable logic
--
-- Features:
-- - Context-aware tracking (disables during menus, loading, braindance, photo mode, scenes)
-- - GameUI event listeners for state change detection
-- - Cached state to avoid repeated API calls per frame
-- - Smooth transition handling (camera reset on state changes)
-- - Tracking allowed/denied status with reason reporting

-- Load GameUI module
local GameUI = require("modules/GameUI")

local State = {}
State.__index = State

-- Gate verdicts are the first thing a "no head tracking" report needs, so they
-- go to HeadTracking.log beside the game EXE rather than only to the CET
-- console. pcall because the call crosses into the native RTTI dispatcher and
-- an error raised there escapes to CET's panic path, which abort()s the game.
local function slog(msg)
    print(msg)
    if type(Game.HeadTrackingLog) == "function" then
        pcall(Game.HeadTrackingLog, msg)
    end
end

-- State reasons for debugging and UI feedback
State.REASON = {
    ALLOWED = "allowed",
    LOADING = "loading",
    MENU = "menu",
    BRAINDANCE = "braindance",
    PHOTO_MODE = "photo_mode",
    SCENE = "scene",
    DISABLED = "disabled",
    NO_PLAYER = "no_player",
    ADS = "ads",  -- Aiming down sights - the game owns the sight picture
    WARMUP = "warmup"  -- Post-scene-load warmup window; prevents applying stale tracking to mid-load camera
}

-- Ordered GameUI predicates; the first one whose method exists AND returns
-- truthy wins. Order matters: the previous if/else cascade walked these in
-- order of likelihood, and we preserve that order here.
local GAMEUI_BLOCK_CHECKS = {
    { method = "IsLoading",    reason = State.REASON.LOADING },
    { method = "IsMenuOpen",   reason = State.REASON.MENU },
    { method = "IsBraindance", reason = State.REASON.BRAINDANCE },
    { method = "IsPhoto",      reason = State.REASON.PHOTO_MODE },
    { method = "IsScene",      reason = State.REASON.SCENE },
}

-- Lookup for human-readable descriptions of every reason.
local REASON_DESCRIPTIONS = {
    [State.REASON.ALLOWED]    = "Head tracking active",
    [State.REASON.LOADING]    = "Tracking paused: Loading screen",
    [State.REASON.MENU]       = "Tracking paused: Menu open",
    [State.REASON.BRAINDANCE] = "Tracking paused: Braindance active",
    [State.REASON.PHOTO_MODE] = "Tracking paused: Photo mode",
    [State.REASON.SCENE]      = "Tracking paused: Cinematic",
    [State.REASON.DISABLED]   = "Head tracking disabled",
    [State.REASON.NO_PLAYER]  = "Tracking paused: No player",
    [State.REASON.ADS]        = "Tracking paused: Aiming down sights",
    [State.REASON.WARMUP]     = "Tracking paused: Warming up after scene load",
}

-- CameraUnlock rule: ~1.5s warmup after a scene/session/load so the camera
-- component has time to initialize before we try to modify it.
local WARMUP_SECONDS = 1.5

-- gameSceneTier values above Tier3_LimitedGameplay are scripted cinematics.
-- At or below it the player still owns the camera, which is what "plain
-- gameplay" has to mean before we clear a GameUI latch as stale.
local SCENE_TIER_LIMITED_GAMEPLAY = 3

-- Live state is re-probed at most this often; between probes the cached
-- verdict stands. Bounding the cache by TIME - not only by a GameUI event -
-- is what lets a missed close event heal itself instead of stranding
-- tracking off until the user reloads mods.
local STATE_CACHE_TTL_S = 0.1

-- How long live state and a GameUI latch must disagree before the latch is
-- treated as stale. The observer edge and the blackboard do not flip on the
-- same frame, so an instantaneous disagreement is just that race and clearing
-- on it would drop a latch the moment its menu opened. A disagreement that
-- outlives this window is a close event that is never coming.
local STALE_LATCH_GRACE_S = 1.0

--- Create a new state tracker instance
--- @return table State instance
function State.new()
    local self = setmetatable({}, State)

    -- Cached state to avoid repeated API calls per frame
    self.cached_allowed = true
    self.cached_reason = State.REASON.ALLOWED
    self.cache_valid = false
    self.cache_time = 0

    -- os.clock() when live state first contradicted a GameUI latch, nil while
    -- the two agree. See STALE_LATCH_GRACE_S.
    self.latch_disagree_since = nil

    -- Reference to camera module for reset on state changes
    self.camera = nil

    -- Reference to settings module for enabled check
    self.settings = nil

    -- Track previous state for change detection
    self.was_tracking_allowed = true

    -- Statistics for debugging
    self.stats = {
        state_checks = 0,
        cache_hits = 0,
        cache_misses = 0,
        state_transitions = 0
    }

    -- True when a weapon is drawn. ADS deliberately has no mirrored flag: it
    -- is polled live from the player state machine instead, see isAdsLive().
    self.has_weapon = false

    -- Whether the last verdict walk found the player aiming down sights.
    -- Cached rather than latched: the walk recomputes it from isAdsLive().
    self.ads_active = false

    -- Whether the last verdict walk found the player looking through the
    -- vehicle chase camera. Same deal as ads_active: recomputed, not latched.
    self.chase_camera = false

    -- Separate baseline for the transition log, because chase_camera is reset
    -- to false at the top of every cache-miss walk. Comparing against it would
    -- make the log fire on every walk while the chase camera is up, and never
    -- fire on the way out.
    self.chase_camera_logged = false

    -- Warmup deadline (os.clock()); tracking suppressed until this passes.
    -- nil means "no warmup active". Armed on loading-finish and session-start.
    self.warmup_deadline = nil

    return self
end

--- Start a warmup window. Any tracking is suppressed until os.clock() passes
--- the deadline. Called from post-load / post-session-start events.
function State:startWarmup()
    self.warmup_deadline = os.clock() + WARMUP_SECONDS
    self:invalidateCache()
end

--- Initialize state tracking and register GameUI listeners
--- @param camera table|nil Optional camera module reference for auto-reset
--- @param settings table|nil Optional settings module reference for enabled check
function State:init(camera, settings)
    self.camera = camera
    self.settings = settings

    -- Register state change listeners to invalidate cache
    if GameUI then
        -- Menu events
        GameUI.Listen("MenuOpen", function()
            self:invalidateCache()
            self:onStateChange("menu_open")
        end)

        GameUI.Listen("MenuClose", function()
            self:invalidateCache()
            self:onStateChange("menu_close")
        end)

        -- Loading events
        GameUI.Listen("LoadingStart", function()
            self:invalidateCache()
            self:onStateChange("loading_start")
        end)

        GameUI.Listen("LoadingFinish", function()
            self:startWarmup()
            self:onStateChange("loading_finish")
        end)

        -- Session events
        GameUI.Listen("SessionStart", function()
            self:startWarmup()
            self:onStateChange("session_start")
        end)

        GameUI.Listen("SessionEnd", function()
            self:invalidateCache()
            self:onStateChange("session_end")
        end)
    end

    -- Weapon and ADS observers. The ADS pair deliberately latches nothing -
    -- the gate polls the state machine - they only drop the cached verdict so
    -- the ADS edge is acted on the frame it arrives rather than up to
    -- STATE_CACHE_TTL_S later.
    local this = self

    Observe("AimingStateEvents", "OnEnter", function(_, stateContext, scriptInterface)
        this:invalidateCache()
    end)

    Observe("AimingStateEvents", "OnExit", function(_, stateContext, scriptInterface)
        this:invalidateCache()
    end)

    -- Observe when weapon is readied (drawn)
    Observe("ReadyEvents", "OnEnter", function(_, stateContext, scriptInterface)
        this.has_weapon = true
        this:invalidateCache()
        slog("[HeadTracking:State] Weapon readied")
    end)

    -- Observe when weapon is unreadied (holstered)
    Observe("ReadyEvents", "OnExit", function(_, stateContext, scriptInterface)
        this.has_weapon = false
        this:invalidateCache()
        slog("[HeadTracking:State] Weapon holstered")
    end)
end

--- Set the camera reference for auto-reset on state changes
--- @param camera table Camera module instance
function State:setCamera(camera)
    self.camera = camera
end

--- Set the settings reference for enabled check
--- @param settings table Settings module instance
function State:setSettings(settings)
    self.settings = settings
end

-- gamePSMUpperBodyStates.Aim - the upper-body state while aiming down sights.
local PSM_UPPERBODY_AIM = 6

--- Poll the player's current UpperBody state-machine value from the
--- PlayerStateMachine blackboard. This is the LIVE current state (not a
--- transition event), so it can't latch the way AimingStateEvents does after
--- a shot. Returns the int state, or nil if it can't be read this frame.
--- @return integer|nil
function State:probeUpperBodyState()
    local ok, val = pcall(function()
        local player = Game.GetPlayer()
        if not player then return nil end
        local defs = GetAllBlackboardDefs()
        local psmBB = Game.GetBlackboardSystem():GetLocalInstanced(
            player:GetEntityID(), defs.PlayerStateMachine)
        if not psmBB then return nil end
        return psmBB:GetInt(defs.PlayerStateMachine.UpperBody)
    end)
    if ok then return val end
    return nil
end

--- Live ADS check, latch-free. Uses the polled UpperBody==Aim state, which
--- reflects the current state rather than a transition event - so it stays
--- correct through firing, unlike AimingStateEvents whose OnExit is not
--- guaranteed to arrive.
---
--- A frame the blackboard cannot be read reports false, not "still aiming".
--- This gates head tracking now, and an unreadable blackboard stranding
--- tracking off for the rest of a session is far worse than one frame of
--- tracking leaking into ADS.
--- @return boolean
function State:isAdsLive()
    return self:probeUpperBodyState() == PSM_UPPERBODY_AIM
end

--- The configured aim-down-sights behaviour, defaulting to the shipped
--- "paused" when settings are not wired up yet (state is constructed before
--- settings in some init orders, and a nil read must not leave the gate open).
--- @return string One of "paused", "marker", "tracked"
function State:adsMode()
    if not self.settings then return "paused" end
    return self.settings:get("ads_mode") or "paused"
end

--- Is the player aiming down sights? Computed by the verdict walk rather than
--- probed separately, so this rides the same cache and costs nothing extra on
--- the frames the caller has already asked for a verdict.
--- @return boolean
function State:isAdsActive()
    self:isTrackingAllowed()
    return self.ads_active and true or false
end

-- The PlayerStateMachine blackboard entry the game sets while the vehicle
-- chase camera is what the player is looking through. Resolved once and
-- remembered, including the "this build does not have it" answer.
--
-- The lookup is isolated from the probe that uses it on purpose. A missing
-- entry read straight off the defs table throws, and this probe is also what
-- answers "is a menu open" - losing menu detection to a field that only the
-- chase camera needs would be a bad trade. Absent, the feature is off and
-- says so once.
local chase_camera_field = nil       -- resolved id
local chase_camera_field_checked = false

local function readChaseCamera(defs, psmBB)
    if not chase_camera_field_checked then
        chase_camera_field_checked = true
        local ok, id = pcall(function() return defs.PlayerStateMachine.IsVehicleInTPP end)
        if ok and id ~= nil then
            chase_camera_field = id
        else
            slog("[HeadTracking:State] PlayerStateMachine.IsVehicleInTPP unavailable - " ..
                 "head tracking in the vehicle chase camera is off on this build")
        end
    end
    if not chase_camera_field then return false end
    return psmBB:GetBool(chase_camera_field) and true or false
end

--- Probe live UI state from the blackboards. This is the CURRENT state, not a
--- transition event, so unlike the GameUI latches it cannot stick after a
--- missed close event. Returns nil when the game is not up far enough to
--- answer (no player, no blackboard yet); the caller then leaves the latched
--- state alone rather than guessing.
--- @return table|nil { in_menu = boolean, plain_gameplay = boolean }
function State:probeLiveUi()
    local ok, res = pcall(function()
        local player = Game.GetPlayer()
        if not player then return nil end
        local defs = GetAllBlackboardDefs()
        local bbs = Game.GetBlackboardSystem()

        local uiBB = bbs:Get(defs.UI_System)
        if not uiBB then return nil end
        local in_menu = uiBB:GetBool(defs.UI_System.IsInMenu) and true or false

        local psmBB = bbs:GetLocalInstanced(player:GetEntityID(), defs.PlayerStateMachine)
        if not psmBB then return nil end
        local tier = psmBB:GetInt(defs.PlayerStateMachine.SceneTier)
        if not tier then return nil end

        return {
            in_menu = in_menu,
            plain_gameplay = (not in_menu) and tier <= SCENE_TIER_LIMITED_GAMEPLAY,
            chase_camera = readChaseCamera(defs, psmBB),
        }
    end)
    if ok then return res end
    return nil
end

--- Record a verdict, stamp the cache, and log the transition. Transition
--- logging is unconditional: a gate that blocks in silence is exactly what
--- made a stuck menu latch invisible for a whole session.
--- @param allowed boolean
--- @param reason string
--- @return boolean the verdict, so callers can `return self:setVerdict(...)`
function State:setVerdict(allowed, reason)
    if allowed ~= self.cached_allowed or reason ~= self.cached_reason then
        if allowed then
            slog("[HeadTracking:State] tracking RESUMED")
        else
            slog("[HeadTracking:State] tracking BLOCKED: " .. tostring(reason))
        end
    end
    self.cached_allowed = allowed
    self.cached_reason = reason
    self.cache_valid = true
    self.cache_time = os.clock()
    return allowed
end

--- Handle state change events for smooth transitions
--- Resets camera when transitioning to a non-allowed state
--- @param event string The event that triggered the state change
function State:onStateChange(event)
    self.stats.state_transitions = self.stats.state_transitions + 1

    -- Check if we're transitioning from allowed to not-allowed
    local now_allowed = self:isTrackingAllowed()

    if self.was_tracking_allowed and not now_allowed then
        -- Transitioning to a state where tracking is not allowed
        -- Reset camera to prevent stuck rotation
        if self.camera then
            self.camera:reset()
        end
    end

    self.was_tracking_allowed = now_allowed
end

--- Check if head tracking is currently allowed
--- Returns false during menus, loading screens, cutscenes, braindance, photo mode
--- Uses cached value when valid to avoid repeated API calls per frame
--- @return boolean true if tracking is allowed, false otherwise
function State:isTrackingAllowed()
    self.stats.state_checks = self.stats.state_checks + 1

    -- Return cached value while it is still fresh (optimization for per-frame
    -- calls). The TTL is the self-healing part: a GameUI close event that never
    -- arrives can no longer pin the verdict for the rest of the session.
    if self.cache_valid and (os.clock() - self.cache_time) < STATE_CACHE_TTL_S then
        self.stats.cache_hits = self.stats.cache_hits + 1
        return self.cached_allowed
    end

    self.stats.cache_misses = self.stats.cache_misses + 1
    -- Recomputed by the ADS check at the end of the walk. An early return
    -- above it (menu, cinematic, warmup) leaves this false, which is what the
    -- callers want: those block tracking outright, so there is no frozen ADS
    -- pose to hold.
    self.ads_active = false
    self.chase_camera = false

    -- Check if tracking is manually disabled via settings. Gate is open if
    -- EITHER rotation or position tracking is on - the position-only mode
    -- (rotation off, position on) is a valid cycle state.
    if self.settings then
        local rot_on = self.settings:get("enabled") and true or false
        local pos_on = self.settings:get("position_enabled") and true or false
        if not rot_on and not pos_on then
            return self:setVerdict(false, State.REASON.DISABLED)
        end
    end

    -- GameUI not available - allow tracking (fail open)
    if not GameUI then
        return self:setVerdict(true, State.REASON.ALLOWED)
    end

    -- Live menu state blocks on its own: it is the current state, so it is
    -- right even on the frames the observer edge has not landed yet.
    local live = self:probeLiveUi()
    if live and live.in_menu then
        return self:setVerdict(false, State.REASON.MENU)
    end

    -- Post-load warmup - suppress tracking until the camera component has
    -- had time to settle after a scene load / session start. The cache TTL is
    -- what expires the window; the deadline is re-read on the next probe.
    if self.warmup_deadline then
        if os.clock() < self.warmup_deadline then
            return self:setVerdict(false, State.REASON.WARMUP)
        end
        self.warmup_deadline = nil
    end

    -- Walk GameUI predicates in order of likelihood; first truthy wins.
    local latched_reason = nil
    for _, check in ipairs(GAMEUI_BLOCK_CHECKS) do
        local method = GameUI[check.method]
        if method and method() then
            latched_reason = check.reason
            break
        end
    end

    -- A latch that says "blocked" while live state says the player owns the
    -- camera is a close event that never arrived. That is what applying
    -- graphics or audio settings does: the game re-creates the menu
    -- controller, the open edge fires again, the close edge does not, and the
    -- gate used to stay shut for the rest of the session.
    if latched_reason and live and live.plain_gameplay then
        local now = os.clock()
        self.latch_disagree_since = self.latch_disagree_since or now
        if (now - self.latch_disagree_since) >= STALE_LATCH_GRACE_S then
            self.latch_disagree_since = nil
            local cleared = GameUI.ResyncStaleUiLatches()
            if cleared then
                print("[HeadTracking:State] cleared stale GameUI latch(es): " .. cleared ..
                      " (live state says gameplay)")
                latched_reason = nil
                -- Clearing a stale loading latch fires LoadingFinish, which
                -- re-arms the warmup this call already walked past.
                if self.warmup_deadline and os.clock() < self.warmup_deadline then
                    return self:setVerdict(false, State.REASON.WARMUP)
                end
            end
        end
    else
        self.latch_disagree_since = nil
    end

    if latched_reason then
        return self:setVerdict(false, latched_reason)
    end

    -- Recorded here rather than at the live probe above, so that the returns
    -- ABOVE this point (menu, warmup, latched GameUI reason) leave it false. It
    -- says where the head rotation should be applied, and through a menu the
    -- answer is nowhere: a flag left true there would keep the native
    -- render-side injection running. The ADS return below is past this point
    -- and does leave it set, which is harmless because init.lua only consults
    -- it as `tracking_allowed and state:isChaseCameraActive()`.
    --
    -- chase_camera_logged is deliberately NOT reset per walk. It is the
    -- transition baseline for the log line, and comparing against a field that
    -- is cleared every walk made the line fire on each cache miss while the
    -- chase camera was up and never fire on the way out.
    if live then
        if live.chase_camera ~= self.chase_camera_logged then
            self.chase_camera_logged = live.chase_camera
            slog("[HeadTracking:State] chase camera (IsVehicleInTPP) -> " ..
                 tostring(live.chase_camera))
        end
        self.chase_camera = live.chase_camera
    end

    -- Aiming down sights: the game pulls the camera onto the weapon's sight
    -- line, and that sight picture IS the aim. What that should do to head
    -- tracking is the user's call, toggled with Insert / Ctrl+Shift+U:
    --   "paused"  - stand tracking down, so the view swings onto the point the
    --               reticle was marking and the sight picture is the game's.
    --   "marker" / "tracked" - keep the gate open. ads_pose.lua feeds poses
    --               relative to the one the sights came up on, so the view
    --               makes that same swing and then keeps tracking from there.
    --               "marker" additionally draws an aim marker at the projected
    --               hit point.
    -- Last in the walk so a menu or cinematic still reports its own reason
    -- when both are true at once.
    if self:isAdsLive() then
        self.ads_active = true
        if self:adsMode() == "paused" then
            return self:setVerdict(false, State.REASON.ADS)
        end
    end

    return self:setVerdict(true, State.REASON.ALLOWED)
end

--- Is the player looking through the vehicle chase camera (third-person
--- driving) rather than a first-person one? Rides the same cache as the
--- verdict, so asking costs nothing on a frame that has already asked.
---
--- This decides WHERE the head rotation is applied, not whether it is applied:
--- the chase camera renders from its own component and ignores every write to
--- the player's FPP camera, so in it the Lua camera path stands down and the
--- native ViewBuilder hook injects into the render params instead.
--- @return boolean
function State:isChaseCameraActive()
    self:isTrackingAllowed()
    return self.chase_camera and true or false
end

--- Get the reason why tracking is currently allowed or denied
--- @return string Reason code from State.REASON
function State:getReason()
    -- Ensure cache is populated
    if not self.cache_valid then
        self:isTrackingAllowed()
    end
    return self.cached_reason
end

--- Check if tracking was allowed in the previous check
--- Useful for detecting state transitions
--- @return boolean true if tracking was previously allowed
function State:wasTrackingAllowed()
    return self.was_tracking_allowed
end

--- Invalidate the state cache (called on state changes)
--- Next call to isTrackingAllowed() will re-check all conditions
function State:invalidateCache()
    self.cache_valid = false
end

--- Force a state recheck and handle transitions
--- Call this when external state changes (e.g., settings toggle)
function State:refresh()
    self:invalidateCache()
    self:onStateChange("manual_refresh")
end

--- Get statistics for debugging
--- @return table Statistics {state_checks, cache_hits, cache_misses, state_transitions}
function State:getStats()
    local hit_rate = 0
    if self.stats.state_checks > 0 then
        hit_rate = (self.stats.cache_hits / self.stats.state_checks) * 100
    end

    return {
        state_checks = self.stats.state_checks,
        cache_hits = self.stats.cache_hits,
        cache_misses = self.stats.cache_misses,
        state_transitions = self.stats.state_transitions,
        cache_hit_rate = hit_rate,
        current_allowed = self.cached_allowed,
        current_reason = self.cached_reason
    }
end

--- Reset statistics counters
function State:resetStats()
    self.stats.state_checks = 0
    self.stats.cache_hits = 0
    self.stats.cache_misses = 0
    self.stats.state_transitions = 0
end

--- Get a human-readable description of the current state
--- @return string Human-readable state description
function State:getStateDescription()
    return REASON_DESCRIPTIONS[self:getReason()] or "Tracking status unknown"
end

return State
