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
    HIPFIRE = "hipfire",  -- Hip-firing - disable head tracking (aim coupled to camera center)
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
    [State.REASON.HIPFIRE]    = "Tracking paused: Hip-fire (aim coupled)",
    [State.REASON.WARMUP]     = "Tracking paused: Warming up after scene load",
}

-- CameraUnlock rule: ~1.5s warmup after a scene/session/load so the camera
-- component has time to initialize before we try to modify it.
local WARMUP_SECONDS = 1.5

--- Create a new state tracker instance
--- @return table State instance
function State.new()
    local self = setmetatable({}, State)

    -- Cached state to avoid repeated API calls per frame
    self.cached_allowed = true
    self.cached_reason = State.REASON.ALLOWED
    self.cache_valid = false

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

    -- Weapon/aiming state tracking
    -- We ENABLE head tracking during ADS - game's ADS provides decoupled aim
    -- Hip-fire DISABLES head tracking - bullets go to screen center (coupled aim)
    self.is_aiming = false  -- True when ADS (aiming down sights)
    self.has_weapon = false -- True when weapon is drawn

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
            if self.camera and self.camera.armAutoRecenter then self.camera:armAutoRecenter() end
            self:onStateChange("loading_finish")
        end)

        -- Session events
        GameUI.Listen("SessionStart", function()
            self:startWarmup()
            if self.camera and self.camera.armAutoRecenter then self.camera:armAutoRecenter() end
            self:onStateChange("session_start")
        end)

        GameUI.Listen("SessionEnd", function()
            self:invalidateCache()
            self:onStateChange("session_end")
        end)
    end

    -- Register weapon/aiming state observers
    -- ADS = head tracking enabled (decoupled aim), hipfire = head tracking disabled
    local this = self

    -- Observe when player starts aiming down sights
    Observe("AimingStateEvents", "OnEnter", function(_, stateContext, scriptInterface)
        this.is_aiming = true
        this:invalidateCache()
        print("[HeadTracking:State] ADS entered - head tracking ENABLED (decoupled aim)")
    end)

    -- Observe when player stops aiming down sights
    Observe("AimingStateEvents", "OnExit", function(_, stateContext, scriptInterface)
        this.is_aiming = false
        this:invalidateCache()
        print("[HeadTracking:State] ADS exited - head tracking DISABLED (hipfire)")
    end)


    -- Observe when weapon is readied (drawn)
    Observe("ReadyEvents", "OnEnter", function(_, stateContext, scriptInterface)
        this.has_weapon = true
        this:invalidateCache()
        print("[HeadTracking:State] Weapon readied")
    end)

    -- Observe when weapon is unreadied (holstered)
    Observe("ReadyEvents", "OnExit", function(_, stateContext, scriptInterface)
        this.has_weapon = false
        this.is_aiming = false  -- Can't be aiming without weapon
        this:invalidateCache()
        print("[HeadTracking:State] Weapon holstered - head tracking enabled")
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
--- correct through firing, unlike the AimingStateEvents-driven is_aiming flag
--- (kept only as a fallback for the rare frame the blackboard can't be read).
--- @return boolean
function State:isAdsLive()
    if self:probeUpperBodyState() == PSM_UPPERBODY_AIM then return true end
    return self.is_aiming == true
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

-- Debug logging control for state
local STATE_DEBUG_LOG_INTERVAL = 180  -- Log every N cache misses
local state_debug_counter = 0

--- Check if head tracking is currently allowed
--- Returns false during menus, loading screens, cutscenes, braindance, photo mode
--- Uses cached value when valid to avoid repeated API calls per frame
--- @return boolean true if tracking is allowed, false otherwise
function State:isTrackingAllowed()
    self.stats.state_checks = self.stats.state_checks + 1

    -- Return cached value if still valid (optimization for per-frame calls)
    if self.cache_valid then
        self.stats.cache_hits = self.stats.cache_hits + 1
        return self.cached_allowed
    end

    self.stats.cache_misses = self.stats.cache_misses + 1
    state_debug_counter = state_debug_counter + 1
    local should_log = (state_debug_counter % STATE_DEBUG_LOG_INTERVAL == 1)

    -- Check if tracking is manually disabled via settings. Gate is open if
    -- EITHER rotation or position tracking is on - the position-only mode
    -- (rotation off, position on) is a valid cycle state.
    if self.settings then
        local rot_on = self.settings:get("enabled") and true or false
        local pos_on = self.settings:get("position_enabled") and true or false
        if not rot_on and not pos_on then
            self.cached_allowed = false
            self.cached_reason = State.REASON.DISABLED
            self.cache_valid = true
            if should_log then
                print("[HeadTracking:State:DEBUG] Tracking DISABLED via settings (rot+pos both off)")
            end
            return false
        end
    end

    -- GameUI not available - allow tracking (fail open)
    if not GameUI then
        self.cached_allowed = true
        self.cached_reason = State.REASON.ALLOWED
        self.cache_valid = true
        if should_log then
            print("[HeadTracking:State:DEBUG] GameUI not available, allowing tracking (fail open)")
        end
        return true
    end

    -- Post-load warmup - suppress tracking until the camera component has
    -- had time to settle after a scene load / session start.
    -- Intentionally does NOT mark cache_valid: re-check time each frame so
    -- warmup naturally expires.
    if self.warmup_deadline then
        if os.clock() < self.warmup_deadline then
            self.cached_allowed = false
            self.cached_reason = State.REASON.WARMUP
            return false
        end
        self.warmup_deadline = nil
    end

    -- Walk GameUI predicates in order of likelihood; first truthy wins.
    for _, check in ipairs(GAMEUI_BLOCK_CHECKS) do
        local method = GameUI[check.method]
        if method and method() then
            self.cached_allowed = false
            self.cached_reason = check.reason
            self.cache_valid = true
            return false
        end
    end

    -- All checks passed - tracking is allowed
    self.cached_allowed = true
    self.cached_reason = State.REASON.ALLOWED
    self.cache_valid = true
    if should_log then
        print("[HeadTracking:State:DEBUG] Tracking ALLOWED (all checks passed)")
    end
    return true
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
