-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Built-in Crosshair Driver
--
-- Moves the game's own crosshair widget so the engine-drawn reticle marks
-- the true aim point under head tracking.
--
-- This module is heavily diagnostic right now because the first attempt
-- showed no visible movement. All meaningful events log to the shared
-- DebugLog file (HeadTracking-diag.log) so we can see what fired across
-- a play session without watching the CET console.
--
-- Status dump from the CET console:
--   GetMod("HeadTracking").DiagReticle()

local BuiltinCrosshair = {}
BuiltinCrosshair.__index = BuiltinCrosshair

local math_rad = math.rad
local math_tan = math.tan
local math_abs = math.abs
local math_exp = math.exp
local math_sqrt = math.sqrt

-- Hoisted pcall trampolines. The per-frame tick path calls
-- GetRootWidget/GetRootCompoundWidget and SetMargin under pcall. A
-- fresh `function() ... end` per call site allocates a closure each frame
-- per controller; module-scope helpers + pcall(_fn, args...) avoid that
-- without losing the error guard.
local function _readCamFov(cam) return cam.fov end
local function _getRootWidget(ctrl) return ctrl:GetRootWidget() end
local function _getRootCompoundWidget(ctrl) return ctrl:GetRootCompoundWidget() end
local function _rootSetMargin(root, m) root:SetMargin(m) end
local function _widgetSetTranslation(w, x, y) w:SetTranslation(x, y) end
local function _widgetGetController(w) return w:GetController() end
local function _getNumChildren(root) return root:GetNumChildren() end
local function _getWidgetByIndex(root, index) return root:GetWidgetByIndex(index) end
local function _getCrosshairData(targeting, player)
    return targeting:GetDefaultCrosshairData(player)
end
local function _getNormalizedWeaponSway()
    local defs = GetAllBlackboardDefs()
    local blackboard = Game.GetBlackboardSystem():Get(defs.UIGameData)
    return blackboard:GetVector2(defs.UIGameData.NormalizedWeaponSway)
end
local function _raycastStatic(spatial, from, to)
    return spatial:SyncRaycastByCollisionGroup(from, to, 'Static', false, false)
end
local function _raycastWorldStatic(spatial, from, to)
    return spatial:SyncRaycastByCollisionPreset(
        from, to, 'World Static', true, false)
end

-- Lock-on gating. The in-car / combat reticle is the SAME widget the engine
-- moves onto an enemy when a target is locked: when locked the game writes the
-- widget's root margin every frame to project the enemy world point through the
-- head-rotated camera, so it lands on the enemy correctly on its own. When NOT
-- locked it sits at screen centre and must be shoved by our head offset so it
-- marks body-forward (where the gun actually fires).
--
-- We tell the two states apart by comparing the widget's CURRENT root margin
-- against the value WE last wrote: if it is off-centre and is NOT the value we
-- wrote, the engine has overwritten it this frame -> a live lock-on projection
-- -> back off and let the engine own it. If it is at rest, or still holds our
-- value, the engine is not driving it -> we apply the body-forward offset.
--
-- Two independent ways the engine positions a locked-on reticle, and how we
-- tell each apart from our own offset:
--
--   * ROOT MARGIN (the in-car bracket canvases): the engine writes the same
--     root margin we write. We compare the current margin to the value WE last
--     wrote - off-centre AND not ours = the engine overwrote it = locked.
--   * SUBTREE TRANSLATION (the on-foot / box crosshair controller): the engine
--     leaves the root margin alone and projects the target by translating a
--     deep child. We NEVER write translation anywhere, so ANY non-trivial
--     translation in the subtree is purely the engine projecting onto a target.
--
-- The gate currently fires only on the root-margin signal. The subtree
-- translation is logged (for discovery) but NOT gated on, because the reticle's
-- children translate for soft-tracking / spread / bloom too.
--
-- RESTING_PX: a root margin this close to (0,0) counts as centred (engine idle).
-- MATCH_EPS:  how close the current margin must be to our last write to count
--             as "still ours" (sub-pixel slack for float round-trips).
-- WALK_DEPTH: subtree depth the discovery log walks for the max-translation read.
local GATE_RESTING_PX = 8.0
local GATE_MATCH_EPS  = 1.0
local GATE_WALK_DEPTH = 6
-- How long a not-ours root margin must stay inside a GATE_MATCH_EPS box before
-- we take it back. Seconds, NOT frames: a frame count means one thing at 30fps
-- and a different thing at 240, and this mod's users run high-refresh displays.
-- See the staleness note in _engineDriving.
local GATE_STALE_SECONDS = 0.15
-- A widget the gate stands down on for this long, while the offset we WANT is
-- meanwhile sweeping, is a widget stuck to the player's head. That is the
-- "reticle unlocks and drifts" report, and it has cost several rounds of
-- guessing for want of the numbers at the moment it happens. Report it once,
-- unprompted, with the values that identify which threshold is holding it.
local GATE_STUCK_SECONDS = 1.0
local GATE_STUCK_INTENDED_PX = 40.0
local AIM_RAY_LENGTH_M = 1000.0
local AIM_DISTANCE_SMOOTH_SPEED = 18.0
local LOCK_CHILD_TRANSLATION_PX = 8.0
-- The child-translation lock heuristic latches ANY visible descendant displaced
-- past LOCK_CHILD_TRANSLATION_PX as an "engine lock-on" and pins the reticle to
-- (0,0). A SHOTGUN's spread reticle has arms permanently displaced past that
-- threshold, so it false-fires and freezes the reticle at view-centre ("drifts
-- with the head"). Disabled: the margin-based _engineDriving signal still backs
-- off for a genuine root-margin lock projection, without the spread false-fire.
local USE_LOCK_CHILD_GATE = false

-- Controllers that draw an on-hit / on-kill marker. Each one is a separate
-- inkGameController owning its own root widget in the HUD layer, so the
-- reticle shove (which only reaches crosshair controller roots) leaves them
-- pinned at screen centre. Sources, from the game's script table:
--   cyberpunk\UI\weapons\crosshairs\kill_marker.script
--   cyberpunk\UI\widgets\cpo\targetHitIndicator.script
local HIT_MARKER_CLASSES = {
    'KillMarkerGameController',
    'TargetHitIndicatorGameController',
}

-- Smart weapons draw one target bracket per tracked enemy. The smart crosshair
-- controller (CrosshairGameController_Smart_Rifl, and the Jailbreak variant)
-- pools those bracket widgets - library item "bucket", logic controller
-- Crosshair_Smart_Rifl_Bucket - inside the crosshair tree we shove to
-- body-forward, and positions each one on its own target, projected through the
-- head-rotated camera. So the engine already lands them on the enemy, and our
-- shove then slides every one of them off by exactly the reticle offset: yaw
-- left, the brackets swing right. Cancelling our offset on the bracket itself
-- keeps the reticle at body-forward AND the brackets on their targets.
--
-- WALK_DEPTH: how deep under a shoved root the bracket pool is looked for.
-- RESCAN_SECONDS: brackets are spawned and returned to the pool as targets come
--   and go, so the list is rebuilt periodically rather than per frame. Held by
--   wall clock: a frame count makes the rescan four times more frequent on a
--   240Hz display than on a 60Hz one, and this walk is the expensive part.
-- CHANNEL_MOVE_PX: how far a bracket's margin (or translation) must travel
--   before that channel counts as the one the engine positions it with.
local SMART_BUCKET_WIDGET_NAME = 'bucket'
local SMART_BUCKET_CONTROLLER = 'Crosshair_Smart_Rifl_Bucket'
local SMART_WALK_DEPTH = 10
local SMART_RESCAN_SECONDS = 0.5
local SMART_CHANNEL_MOVE_PX = 1.0

-- Self-probe for the bracket work, armed from the console with
-- DiagSmartProbe(seconds) and off otherwise. The CET console log buffers, so a
-- console dump can sit unwritten for minutes while the game is up; this writes
-- through open/append/close instead, which lands on disk immediately. That is
-- the right trade for a probe someone is watching and the wrong one for every
-- session: it used to self-arm for 240 snapshots, which put a burst of
-- synchronous file writes on the render thread twice a second for the first
-- couple of minutes of every launch, on installs with no smart weapon anywhere
-- near them. Exported so init.lua truncates the same file it appends to.
local SMART_PROBE_PATH = "HeadTracking-smart.log"
BuiltinCrosshair.SMART_PROBE_PATH = SMART_PROBE_PATH
local SMART_PROBE_INTERVAL_SECONDS = 0.5

local function slog(msg)
    local f = io.open(SMART_PROBE_PATH, "a")
    if not f then return end
    f:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), msg))
    f:close()
end

-- DebugLog is required lazily on first use so this module's file-scope is
-- side-effect free and cannot fail at require-time inside CET's sandbox.
local _debug_log_resolved = false
local _debug_log_write = nil
-- Reaches HeadTracking.log beside the game EXE, which is the file a "reticle is
-- stuck" report has to be answerable from. pcall because it crosses into the
-- native RTTI dispatcher and a raise there escapes to CET's panic path.
local function htlog(msg)
    print(msg)
    if type(Game.HeadTrackingLog) == "function" then
        pcall(Game.HeadTrackingLog, msg)
    end
end

local function dlog(msg)
    print(msg)
    if not _debug_log_resolved then
        _debug_log_resolved = true
        local ok, DebugLog = pcall(require, "modules/debuglog")
        if ok and DebugLog and DebugLog.write then
            _debug_log_write = DebugLog.write
        end
    end
    if _debug_log_write then pcall(_debug_log_write, msg) end
end

-- Wrapped Observe / ObserveAfter helpers. CET's mod sandbox exposes these
-- as direct globals (Observe / ObserveAfter), not necessarily through _G,
-- so we reference them by name and pcall the lookup itself.
-- Class/method pairs the game does NOT declare, so we must not try to bind
-- them.
--
-- CET's Observe does not raise on a missing method: it logs "Function X in
-- class Y does not exist" to CET's own scripting.log and returns normally, so
-- a pcall around it succeeds and the binding is a silent no-op. That is why
-- tryBind used to report "bound OK" for hooks that never attached, and why a
-- whole day went into explaining behaviour produced by code that never ran.
--
-- Querying the RTTI registry from Lua would be better than a list, but this
-- CET build exposes no working Reflection.GetClass (an attempt returned no
-- usable answer and every probe fell through to "assume present"), so the
-- authoritative source is what CET itself reported. Every entry below was
-- copied from a "does not exist" line in scripting.log.
--
-- If a game patch adds one of these, the only cost is that we keep skipping a
-- hook that would now work. If a patch REMOVES a method not listed here, CET
-- starts logging it again and the name belongs in this table.
local KNOWN_ABSENT = {
    gameuiCrosshairContainerController = {
        OnBulletSpreadChanged = true, OnCurrentRaycastTarget = true,
        UpdateCrosshairState = true,
    },
    -- Neither spelling of the driver-combat HUD controller declares a
    -- teardown method. The gate reset it used to carry now rides the
    -- VehicleComponent unmount observer below, which does exist.
    DriverCombatHUDGameController = { OnUninitialize = true },
    gameuiDriverCombatHUDGameController = { OnUninitialize = true },
}

local function methodAbsent(class, method)
    local t = KNOWN_ABSENT[class]
    return t ~= nil and t[method] == true
end

local function tryBind(api_name, class, method, fn)
    local ok_lookup, api = pcall(function()
        if api_name == 'Observe' then return Observe end
        if api_name == 'ObserveAfter' then return ObserveAfter end
        return nil
    end)
    if not ok_lookup or api == nil then
        dlog(string.format("[HeadTracking:Reticle] %s global unavailable", api_name))
        return false
    end
    if methodAbsent(class, method) then
        dlog(string.format("[HeadTracking:Reticle] %s(%s,%s) SKIPPED: the game does not declare it",
            api_name, class, method))
        return false
    end
    local ok, err = pcall(api, class, method, fn)
    if not ok then
        dlog(string.format("[HeadTracking:Reticle] %s(%s,%s) FAILED: %s",
            api_name, class, method, tostring(err)))
        return false
    end
    dlog(string.format("[HeadTracking:Reticle] %s(%s,%s) bound OK",
        api_name, class, method))
    return true
end

function BuiltinCrosshair.new(settings, camera)
    if not settings then
        error("[HeadTracking] BuiltinCrosshair.new() requires settings")
    end
    if not camera then
        error("[HeadTracking] BuiltinCrosshair.new() requires camera")
    end

    local self = setmetatable({}, BuiltinCrosshair)
    self.settings = settings
    self.camera = camera

    -- controller entries: { ctrl = userdata, class = string,
    --                       root_ok = bool, set_translation_ok = bool,
    --                       set_margin_ok = bool, parent_ok = bool }
    self.controllers = {}
    -- One entry per class for a controller adopted while already live (see
    -- _adopt), plus the cached union of both sets used by the write path.
    self._adopted = {}
    self._entries_cache = nil
    self._entries_dirty = true

    -- Captured gameuiNpcNameplateGameController instances (the in-combat
    -- lock-on box). Read-only probe target: prior work proved writing their
    -- margin does nothing, but we never read back where the GAME places them
    -- each frame. _np_probe_frames > 0 enables the per-frame read logger.
    self.nameplates = {}
    -- On-hit / on-kill marker controllers. Each is its own inkGameController
    -- with its own root widget in the HUD layer (kill_marker.script,
    -- targetHitIndicator.script), NOT a child of the crosshair, so the reticle
    -- shove never reaches them and they draw at screen centre while the reticle
    -- sits on the true aim point. DamageInfo supplies their exact world point.
    self.hit_markers = {}
    self._np_probe_frames = 0
    self._ch_probe_frames = 0
    self._hm_probe_frames = 0
    self._gate_log_frames = 0
    self._lock_probe_frames = 0

    self.enabled = settings:get("crosshair_enabled")

    self._last_dx = 0
    self._last_dy = 0
    self._aim_distance = nil
    self._aim_distance_sample_t = nil
    self._aim_distance_error_logged = false
    self._hit_marker_tracking_allowed = false

    -- Diagnostic: when true, tick() skips all crosshair/bracket writes so the
    -- game's native projection is left untouched. Used to decide whether the
    -- lock-on box drift is our own root-margin shove (box is a crosshair child
    -- the game already projects correctly through the head-rotated cam) versus
    -- a genuine separate-camera projection. Toggle via DiagCrosshairSuppress.
    self._suppress_writes = false

    -- Diagnostic: when false, the hit/kill marker controllers are left where
    -- the game puts them (screen centre). Toggle via DiagShoveHitMarker.
    self._shove_hitmarker = true

    -- Scale factor applied to the in-car bracket offset. A margin unit on the
    -- DriverCombat bracket canvas is half a screen pixel (the dot's controller
    -- root is 1:1), so the dot's dx/dy under-moves the brackets by 2x. Tuned
    -- live to 2.0 via GetMod("HeadTracking").DiagBracketScale(n) and confirmed
    -- 1:1; the tuner stays exposed in case a different UI scale needs it.
    self.bracket_scale = 2.0

    -- Smart-weapon target brackets: the pooled widgets we cancel our shove on,
    -- how they were identified, and which position channel we took. All three
    -- are resolved live (see _writeSmartTargets) and cleared with the gate
    -- state, so a HUD teardown cannot strand a stale widget list.
    self._smart_buckets = nil
    self._smart_find_mode = nil
    self._smart_chan = nil
    self._smart_probe = nil
    self._smart_rescan_t = nil
    self.smart_scale = 1.0

    -- Counters for the status dump
    self._stat = {
        observe_fired = 0,
        observe_after_fired = 0,
        on_update_fired = 0,
        ticks_with_zero_ctrls = 0,
        ticks_with_offset = 0,
        write_attempts = 0,
        write_root_translate_ok = 0,
        write_root_margin_ok = 0,
        write_parent_translate_ok = 0,
        last_error = nil,
    }

    settings:observe("*", function(key)
        if key == "crosshair_enabled" then
            self.enabled = settings:get("crosshair_enabled")
            if not self.enabled then self:_resetAll() end
        end
    end)

    -- Observer install is wrapped: a sandbox restriction here must NOT
    -- prevent the constructor from returning, or head tracking dies.
    local ok_obs, err_obs = pcall(function() self:_installObservers() end)
    if not ok_obs then
        print("[HeadTracking:Reticle] observer install threw (non-fatal): " ..
            tostring(err_obs))
    end

    return self
end

function BuiltinCrosshair:_track(class, this, source)
    for i = 1, #self.controllers do
        if self.controllers[i].ctrl == this then return end
    end
    local entry = {
        ctrl = this,
        class = class,
        source = source,
        root_ok = nil,
        set_translation_ok = nil,
        set_margin_ok = nil,
        parent_ok = nil,
    }
    self.controllers[#self.controllers + 1] = entry
    self._entries_dirty = true
    dlog(string.format(
        "[HeadTracking:Reticle] captured (%s via %s); live count=%d",
        class, source, #self.controllers))

    -- Probe widget access once at capture time so the dump shows whether
    -- the methods exist before we ever try to use them in anger.
    local ok_root, root = pcall(function() return this:GetRootWidget() end)
    entry.root_ok = ok_root and root ~= nil
    if not entry.root_ok then
        local ok_compound, compound = pcall(function() return this:GetRootCompoundWidget() end)
        if ok_compound and compound ~= nil then
            entry.root_ok = true
            entry.using_compound = true
            dlog("[HeadTracking:Reticle]   GetRootWidget() nil; falling back to GetRootCompoundWidget()")
        end
    end
    if entry.root_ok then
        dlog(string.format("[HeadTracking:Reticle]   root widget acquired (%s)",
            entry.using_compound and "compound" or "root"))
    else
        dlog("[HeadTracking:Reticle]   root widget UNAVAILABLE on this controller")
    end
end

--- Adopt the crosshair controller that is already live - the case a mod reload
--- or a late start leaves us in, where OnInitialize has long since fired and
--- nothing would ever be captured. Exactly one entry per class, its handle
--- swapped in place on every callback, so the list cannot grow and the entry's
--- gate store survives.
function BuiltinCrosshair:_adopt(class, this)
    local entry = self._adopted[class]
    if entry ~= nil then
        entry.ctrl = this
        return
    end
    self._adopted[class] = {
        ctrl = this,
        class = class,
        source = 'adopted',
        _lw = {},
    }
    self._entries_dirty = true
    dlog(string.format("[HeadTracking:Reticle] adopted live controller (%s)", class))
end

--- Every controller entry we write to: the ones captured at OnInitialize plus
--- the adopted live one per class. Cached, rebuilt only when the set changes,
--- so the per-frame write path does not allocate.
function BuiltinCrosshair:_entries()
    if self._entries_cache == nil or self._entries_dirty then
        local out = {}
        for i = 1, #self.controllers do out[#out + 1] = self.controllers[i] end
        for _, entry in pairs(self._adopted) do out[#out + 1] = entry end
        self._entries_cache = out
        self._entries_dirty = false
    end
    return self._entries_cache
end

function BuiltinCrosshair:_untrack(this)
    for i = #self.controllers, 1, -1 do
        if self.controllers[i].ctrl == this then
            dlog(string.format("[HeadTracking:Reticle] released (%s)",
                self.controllers[i].class))
            table.remove(self.controllers, i)
            self._entries_dirty = true
            return
        end
    end
end

function BuiltinCrosshair:_trackNameplate(this)
    for i = 1, #self.nameplates do
        if self.nameplates[i] == this then return end
    end
    self.nameplates[#self.nameplates + 1] = this
    dlog(string.format("[HeadTracking:Nameplate] captured; live count=%d", #self.nameplates))
end

function BuiltinCrosshair:_untrackNameplate(this)
    for i = #self.nameplates, 1, -1 do
        if self.nameplates[i] == this then
            table.remove(self.nameplates, i)
            return
        end
    end
end

function BuiltinCrosshair:_trackHitMarker(class, this)
    for i = 1, #self.hit_markers do
        if self.hit_markers[i].ctrl == this then return end
    end
    self.hit_markers[#self.hit_markers + 1] = {
        ctrl = this,
        class = class,
    }
    dlog(string.format("[HeadTracking:HitMarker] captured (%s); live count=%d",
        class, #self.hit_markers))
end

function BuiltinCrosshair:_untrackHitMarker(this)
    for i = #self.hit_markers, 1, -1 do
        if self.hit_markers[i].ctrl == this then
            table.remove(self.hit_markers, i)
            return
        end
    end
end

-- Takes the offset tick already computed. Deriving its own cost a second
-- _computeOffset every frame, and that is not a cheap call: GetCrosshairData
-- alone re-enters Lua through our own TargetingSystem Override, which pulls
-- three more camera-system reads behind it.
function BuiltinCrosshair:_writeHitMarkersAtAim(dx, dy, valid)
    if not self._shove_hitmarker or not self._hit_marker_tracking_allowed then return end
    if valid then self:_writeHitMarkers(dx, dy) end
end

-- Wipe every per-widget gate store. The gate compares the widget's current root
-- margin against the value we last wrote, and tracks per-widget "visible
-- displaced child" sets to spot lock-on projections. Both stores persist across
-- context changes that don't uninitialize the controller (entering a vehicle
-- doesn't always uninitialize the on-foot crosshair controllers, and the
-- bracket-widget gate stores are keyed by index, not widget identity). Without
-- a reset, a stale "lock-child" latch carries over: the next frame after the
-- transition still sees a displaced child in store._lock_active, returns
-- locked=true, and _writeOne actively writes margin (0,0) every frame -
-- pinning the reticle at screen centre even though head tracking is otherwise
-- working. Symptom: drive a vehicle for a while, dismount, reticle stays dead
-- centre while the head still moves the view.
function BuiltinCrosshair:_resetGateState()
    local entries = self:_entries()
    for i = 1, #entries do
        entries[i]._lw = nil
    end
    self._bracket_lw = nil
    -- Pooled smart brackets are torn down with the HUD, so the cached widget
    -- list goes stale on the same transitions the gate stores do. The channel
    -- decision survives - it is a property of the widget, not the instance.
    self._smart_buckets = nil
    self._smart_probe = nil
    self._smart_rescan_t = nil
    self._last_dx = 0
    self._last_dy = 0
end

-- Walk a widget subtree (depth-capped) and return the descendant with the
-- largest |translation|, plus its name and (tx,ty). This is how we find which
-- widget the game actually moves to position the lock-on box on the enemy -
-- the root may stay at (0,0) while a deep child carries the projected offset.
local function _maxTranslationWidget(widget, depth, max_depth, best)
    if widget == nil or depth > max_depth then return best end
    local tx, ty = 0, 0
    pcall(function() local t = widget:GetTranslation(); tx, ty = t.X or t.x or 0, t.Y or t.y or 0 end)
    local mag = math.abs(tx) + math.abs(ty)
    if best == nil or mag > best.mag then
        local name = "?"
        pcall(function()
            local n = widget:GetName()
            name = (Game and Game.NameToString and Game.NameToString(n)) or tostring(n)
        end)
        best = { mag = mag, name = name, tx = tx, ty = ty }
    end
    local ok_n, n = pcall(function() return widget:GetNumChildren() end)
    if ok_n and type(n) == "number" and n > 0 then
        for i = 0, n - 1 do
            local ok_c, child = pcall(function() return widget:GetWidgetByIndex(i) end)
            if ok_c and child ~= nil then
                best = _maxTranslationWidget(child, depth + 1, max_depth, best)
            end
        end
    end
    return best
end

-- Decide whether the engine is positioning `root`'s reticle onto a locked
-- target via its own root margin this frame. Returns (reason, cur_l, cur_t,
-- child_mag):
--   reason == "margin" -> engine overwrote the root margin off-centre to a
--                         value that is not ours -> leave it entirely.
--   reason == nil      -> engine idle (or only soft-tracking) -> we shove the
--                         root margin to body-forward.
-- The subtree-translation signal is NOT used to gate: the reticle's children
-- translate for soft target-tracking, spread and bloom too, none of which is a
-- hard lock, so it false-fires constantly in free aim. The real hard-lock
-- signal (the lock-on rectangle appearing) is being discovered via
-- probeLockSignal; child_mag is computed only when the gate log is armed.
-- `store` is a per-widget table we own carrying {l,t} of our last margin write.
local function _clearHold(store)
    if store then store.anchor_l, store.anchor_t, store.static_since = nil, nil, nil end
end

local function _engineDriving(root, store, compute_child, want_l, want_t)
    local l, t = 0, 0
    pcall(function() local m = root:GetMargin(); l, t = m.left or 0, m.top or 0 end)

    local child_mag = 0
    if compute_child then
        local best = _maxTranslationWidget(root, 0, GATE_WALK_DEPTH, nil)
        child_mag = best and best.mag or 0
    end

    local margin_off = math_abs(l) >= GATE_RESTING_PX or math_abs(t) >= GATE_RESTING_PX
    local is_ours = store.l ~= nil and math_abs(l - store.l) < GATE_MATCH_EPS
                                   and math_abs(t - store.t) < GATE_MATCH_EPS

    -- Or it already holds the offset we are about to write, which means this
    -- mod put it there even though THIS entry did not.
    --
    -- `store` is per ENTRY, but the margin is per WIDGET, and several entries
    -- point at the same root: the tree rediscovers during play and the same
    -- controller comes back with a handle that does not compare equal, so it is
    -- tracked again. Only one of those entries can ever have store.l matching
    -- the actual margin. Every other one sees "not mine" and, because a sibling
    -- is rewriting that margin every frame to follow the head, also sees it
    -- moving, so it holds forever. Two captures show exactly that, the second
    -- with a populated store:
    --   margin=(163.2,9.0)  lastWrote=(nil,nil)      intended=(163.2,9.0)
    --   margin=(384.3,31.2) lastWrote=(-101.3,53.1)  intended=(384.3,31.2)
    -- In both, the margin is precisely what we wanted, so nothing was wrong
    -- with the widget: the gate was refusing to recognise our own work.
    if not is_ours and want_l ~= nil
            and math_abs(l - want_l) < GATE_MATCH_EPS
            and math_abs(t - want_t) < GATE_MATCH_EPS then
        is_ours = true
        store.l, store.t = l, t
    end

    -- A widget we have never written is not evidence of anything. `is_ours`
    -- requires a previous write to compare against, so on a brand new entry it
    -- is false by construction, and if that entry is adopted at a moment the
    -- margin is already off centre the gate calls it engine-owned. It then
    -- never writes, so the store never gains a value, so `is_ours` is false
    -- again next frame: a permanent hold, entered on nothing more than when the
    -- entry happened to be created.
    --
    -- Worse, the hold cannot even time out. The margin it is watching is being
    -- moved every frame by ANOTHER entry pointing at the same root, so the
    -- anchor never settles and static_since resets forever.
    --
    -- The crosshair tree is rediscovered during play (a capture went from
    -- roots=1 to roots=9 mid-session, and found a 20-strong bracket pool at the
    -- same moment), and whether a fresh entry is
    -- born healthy or born stuck came down to how far off centre the reticle
    -- was at that instant. Under GATE_RESTING_PX it claimed the widget and was
    -- fine; over it, stuck for the session. That is the "unlocks once it gets
    -- near the edge" report: not the edge, the offset size when the entry
    -- appeared.
    --
    -- So claim an unseen widget. One write populates the store, and the frame
    -- after that the comparison is real and the normal hold logic applies.
    if store.l == nil then
        store.anchor_l, store.anchor_t, store.static_since = nil, nil, nil
        return nil, l, t, child_mag
    end

    -- "The engine owns this widget" has to mean the engine is POSITIONING it,
    -- not that it once wrote a value here. Testing the value alone made the
    -- gate one-way: a single engine write leaves a margin that is not ours, we
    -- skip our write, and because we skip it `store` never catches up, so the
    -- comparison fails identically forever and that controller is never
    -- compensated again for the rest of the session. A gate probe caught
    -- exactly that, one crosshair controller frozen at cur=(16.7,-6.6) /
    -- lastWrote=(-5.9,6.8) for 79 straight frames while the intended offset
    -- swept 280px and every other controller tracked it perfectly.
    --
    -- So hold off only while the margin is actually MOVING. Displacement is
    -- measured from an ANCHOR - the value when the hold began - rather than
    -- frame to frame, which is what keeps this honest at any frame rate. A
    -- per-frame delta says "not moving" for any projection slower than
    -- GATE_MATCH_EPS per frame, and that bar rises with refresh rate: a lock-on
    -- sliding at 240px/s clears 1px/frame at 60Hz and misses it at 240Hz. The
    -- anchor also absorbs sub-pixel jitter, which a per-frame delta would read
    -- as continuous motion and never release.
    --
    -- Keep the hold SHORT. Every frame of it is a frame the reticle is not
    -- compensated, and the engine re-asserting its resting offset starts it
    -- over, which is what made the shotgun drift in bursts rather than
    -- constantly once the permanent latch was gone.
    --
    -- Do NOT try to adopt the resting value as a baseline and compose onto it.
    -- That was tried and reverted: `is_ours` is the only thing separating the
    -- engine's value from our own, it is an exact match within GATE_MATCH_EPS,
    -- and any single frame where it fails (an engine write landing between our
    -- read and our write, a skipped write, a float round-trip) means the value
    -- adopted as "the game's placement" is our own last composed offset. The
    -- next write adds the offset again, the frame after that adopts THAT, and
    -- every reticle walks off screen in a straight diagonal line. Telling our
    -- contribution from the engine's needs a signal this gate does not have.
    if margin_off and not is_ours then
        local anchored = store.anchor_l ~= nil
            and math_abs(l - store.anchor_l) < GATE_MATCH_EPS
            and math_abs(t - store.anchor_t) < GATE_MATCH_EPS
        if not anchored then
            store.anchor_l, store.anchor_t, store.static_since = l, t, os.clock()
        end
        if (os.clock() - store.static_since) < GATE_STALE_SECONDS then
            return "margin", l, t, child_mag
        end
    elseif not margin_off then
        -- Cleared only when the margin is genuinely back at rest near centre.
        --
        -- Clearing it whenever the value was OURS threw away the one fact worth
        -- keeping: that this particular engine value has already been waited
        -- out. A crosshair whose resting offset the engine re-asserts and we
        -- overwrite alternates ours/engine's every frame or two, and clearing
        -- on each of our frames restarted the hold on each of the engine's, so
        -- the reticle spent most of its time inside a hold and never longer
        -- than GATE_STALE_SECONDS outside one. Keeping the anchor means the
        -- second and later re-assertions of the SAME value are recognised
        -- immediately and reclaimed with no hold at all. A different value
        -- still fails the anchor test and starts a fresh hold, which is the
        -- behaviour that matters for a real projection.
        store.anchor_l, store.anchor_t, store.static_since = nil, nil, nil
    end
    return nil, l, t, child_mag
end

local function _collectVisibleDisplacedWidgets(widget, depth, max_depth, root_margin_l, root_margin_t, out)
    if widget == nil or depth > max_depth then return end
    local vis = false
    pcall(function() vis = widget:IsVisible() and true or false end)
    if vis then
        local tx, ty = 0, 0
        pcall(function() local t = widget:GetTranslation(); tx, ty = t.X or t.x or 0, t.Y or t.y or 0 end)
        local mag = math_abs(tx) + math_abs(ty)

        if mag >= LOCK_CHILD_TRANSLATION_PX then
            local looks_like_our_root_offset =
                depth == 0 and
                math_abs(tx - root_margin_l) < GATE_MATCH_EPS and
                math_abs(ty - root_margin_t) < GATE_MATCH_EPS
            if not looks_like_our_root_offset then
                local name = "?"
                pcall(function()
                    local n = widget:GetName()
                    name = (Game and Game.NameToString and Game.NameToString(n)) or tostring(n)
                end)
                out[name] = { mag = mag, name = name, tx = tx, ty = ty }
            end
        end
    end

    local ok_n, n = pcall(function() return widget:GetNumChildren() end)
    if ok_n and type(n) == "number" and n > 0 then
        for i = 0, n - 1 do
            local ok_c, child = pcall(function() return widget:GetWidgetByIndex(i) end)
            if ok_c and child ~= nil then
                _collectVisibleDisplacedWidgets(child, depth + 1, max_depth, root_margin_l, root_margin_t, out)
            end
        end
    end
end

local function _lockStateFromVisibleChanges(root, store, cur_l, cur_t)
    local cur = {}
    _collectVisibleDisplacedWidgets(root, 0, GATE_WALK_DEPTH, cur_l, cur_t, cur)

    if store._lock_prev == nil then
        store._lock_prev = cur
        store._lock_active = {}
        return false, 0
    end
    store._lock_active = store._lock_active or {}
    for name, w in pairs(cur) do
        if not store._lock_prev[name] then
            store._lock_active[name] = true
            store._lock_last = w
        end
    end
    for name in pairs(store._lock_active) do
        if not cur[name] then
            store._lock_active[name] = nil
        end
    end
    store._lock_prev = cur

    for name in pairs(store._lock_active) do
        local w = cur[name] or store._lock_last
        return true, w and w.mag or 0
    end
    return false, 0
end

-- Per-frame read-probe: for each live nameplate, log the head yaw alongside
-- the root translation/margin AND the deepest most-displaced child, so we can
-- correlate the box's on-screen drift with head motion and find the handle the
-- game writes. Throttled to ~every 6th frame. Read-only; never writes.
function BuiltinCrosshair:_probeNameplatesTick()
    self._np_probe_frames = self._np_probe_frames - 1
    self._np_probe_log_ctr = (self._np_probe_log_ctr or 0) + 1
    if (self._np_probe_log_ctr % 6) ~= 0 then return end
    local yaw, pitch = self.camera:getRenderedYPR(0)
    for i = 1, #self.nameplates do
        local ctrl = self.nameplates[i]
        local ok_root, root = pcall(_getRootWidget, ctrl)
        if not ok_root or root == nil then
            ok_root, root = pcall(_getRootCompoundWidget, ctrl)
        end
        if ok_root and root then
            local rtx, rty = 0, 0
            pcall(function() local t = root:GetTranslation(); rtx, rty = t.X or t.x or 0, t.Y or t.y or 0 end)
            local rmL, rmT = 0, 0
            pcall(function() local m = root:GetMargin(); rmL, rmT = m.left or 0, m.top or 0 end)
            local best = _maxTranslationWidget(root, 0, 8, nil)
            dlog(string.format(
                "[HeadTracking:Nameplate] yaw=%.1f pitch=%.1f | root trans=(%.1f,%.1f) margin=(%.1f,%.1f) | maxchild '%s' trans=(%.1f,%.1f)",
                yaw, pitch, rtx, rty, rmL, rmT,
                best and best.name or "?", best and best.tx or 0, best and best.ty or 0))
        end
    end
end

-- Rotate a 3-component vector by a unit quaternion (q.i,j,k,r). Standard
-- v' = v + 2*cross(q.xyz, cross(q.xyz, v) + q.r*v).
local function _quatRotateVec3(q, vx, vy, vz)
    local qx, qy, qz, qw = q.i, q.j, q.k, q.r
    local tx = 2 * (qy * vz - qz * vy)
    local ty = 2 * (qz * vx - qx * vz)
    local tz = 2 * (qx * vy - qy * vx)
    local rx = vx + qw * tx + (qy * tz - qz * ty)
    local ry = vy + qw * ty + (qz * tx - qx * tz)
    local rz = vz + qw * tz + (qx * ty - qy * tx)
    return rx, ry, rz
end

-- Hamilton product (CET Quaternion has no * operator).
local function _quatMul(a, b)
    return {
        i = a.r * b.i + a.i * b.r + a.j * b.k - a.k * b.j,
        j = a.r * b.j - a.i * b.k + a.j * b.r + a.k * b.i,
        k = a.r * b.k + a.i * b.j - a.j * b.i + a.k * b.r,
        r = a.r * b.r - a.i * b.i - a.j * b.j - a.k * b.k,
    }
end

-- One-shot anchor probe: for each captured nameplate, try to reach the NPC
-- entity it tracks and read its world position, then project that point
-- through the HEAD-ROTATED camera (player world orientation * FPP-cam local
-- orientation) to compute where the box SHOULD be drawn. Logs the screen
-- offset from centre so we can confirm we can compute the correct position
-- ourselves (the prerequisite for a custom-drawn box). Read-only.
function BuiltinCrosshair:probeNameplateAnchor()
    dlog("[HeadTracking:NPAnchor] ===== anchor probe =====")
    local player = Game and Game.GetPlayer and Game.GetPlayer()
    if not player then dlog("[HeadTracking:NPAnchor] no player"); return end
    local cam = player.GetFPPCameraComponent and player:GetFPPCameraComponent()
    if not cam then dlog("[HeadTracking:NPAnchor] no FPP cam"); return end

    -- World orientation of the head-rotated camera.
    local pw, lc
    pcall(function() pw = player:GetWorldOrientation() end)
    pcall(function() lc = cam:GetLocalOrientation() end)
    if not pw or not lc then dlog("[HeadTracking:NPAnchor] missing orient (pw or lc nil)"); return end
    local worldQ = _quatMul(
        { i = pw.i, j = pw.j, k = pw.k, r = pw.r },
        { i = lc.i, j = lc.j, k = lc.k, r = lc.r })
    -- CP2077 basis: forward +Y, right +X, up +Z.
    local fx, fy, fz = _quatRotateVec3(worldQ, 0, 1, 0)
    local rx, ry, rz = _quatRotateVec3(worldQ, 1, 0, 0)
    local ux, uy, uz = _quatRotateVec3(worldQ, 0, 0, 1)

    local cpos
    pcall(function() cpos = cam:GetWorldPosition() end)
    if not cpos then pcall(function() cpos = player:GetWorldPosition() end) end
    if not cpos then dlog("[HeadTracking:NPAnchor] no cam/player world position"); return end
    local cpx, cpy, cpz = cpos.x or cpos.X or 0, cpos.y or cpos.Y or 0, cpos.z or cpos.Z or 0
    dlog(string.format("[HeadTracking:NPAnchor] cam pos=(%.2f,%.2f,%.2f) fwd=(%.2f,%.2f,%.2f)",
        cpx, cpy, cpz, fx, fy, fz))

    local screen_w, screen_h = GetDisplayResolution()
    if not screen_w or screen_w <= 0 then screen_w, screen_h = 1920, 1080 end
    local vfov = 60.0
    local ok, raw = pcall(_readCamFov, cam)
    if ok and type(raw) == "number" and raw > 0 then vfov = raw end
    local tan_half_v = math_tan(math_rad(vfov) * 0.5)
    local tan_half_h = tan_half_v * (screen_w / screen_h)

    local accessors = { "GetOwner", "GetOwnerEntity", "GetGameObject", "GetEntity", "GetNPCObject" }
    for i = 1, #self.nameplates do
        local ctrl = self.nameplates[i]
        local ent = nil
        local hit = "none"
        for _, name in ipairs(accessors) do
            local okc, res = pcall(function() return ctrl[name] and ctrl[name](ctrl) end)
            if okc and res ~= nil then ent = res; hit = name; break end
        end
        if ent == nil then
            dlog(string.format("[HeadTracking:NPAnchor] nameplate[%d]: no entity via any accessor", i))
        else
            local wp = nil
            pcall(function() wp = ent:GetWorldPosition() end)
            if wp == nil then
                dlog(string.format("[HeadTracking:NPAnchor] nameplate[%d]: entity via %s but no GetWorldPosition", i, hit))
            else
                local px, py, pz = wp.x or wp.X or 0, wp.y or wp.Y or 0, wp.z or wp.Z or 0
                local dx_, dy_, dz_ = px - cpx, py - cpy, pz - cpz
                local cf = dx_ * fx + dy_ * fy + dz_ * fz   -- camera-forward depth
                local cr = dx_ * rx + dy_ * ry + dz_ * rz   -- camera-right
                local cu = dx_ * ux + dy_ * uy + dz_ * uz   -- camera-up
                if cf <= 0.01 then
                    dlog(string.format("[HeadTracking:NPAnchor] nameplate[%d] (%s) world=(%.2f,%.2f,%.2f) BEHIND camera (cf=%.2f)", i, hit, px, py, pz, cf))
                else
                    local ndc_x = (cr / cf) / tan_half_h
                    local ndc_y = (cu / cf) / tan_half_v
                    local sx = (0.5 + 0.5 * ndc_x) * screen_w
                    local sy = (0.5 - 0.5 * ndc_y) * screen_h
                    dlog(string.format(
                        "[HeadTracking:NPAnchor] nameplate[%d] (%s) world=(%.2f,%.2f,%.2f) -> head-rot screen=(%.0f,%.0f) [centre=%.0f,%.0f] off=(%.0f,%.0f)",
                        i, hit, px, py, pz, sx, sy, screen_w * 0.5, screen_h * 0.5,
                        sx - screen_w * 0.5, sy - screen_h * 0.5))
                end
            end
        end
    end
    dlog("[HeadTracking:NPAnchor] ===== end anchor probe =====")
end

--- Hide / show the native nameplate boxes by toggling root visibility. Tests
--- whether visibility (unlike margin) survives the native projection layer.
---   GetMod("HeadTracking").DiagNameplateHide(true)   -- hide
---   GetMod("HeadTracking").DiagNameplateHide(false)  -- restore
function BuiltinCrosshair:setNameplatesHidden(hidden)
    local v = not hidden
    local n = 0
    for i = 1, #self.nameplates do
        local ctrl = self.nameplates[i]
        local ok_root, root = pcall(_getRootWidget, ctrl)
        if not ok_root or root == nil then ok_root, root = pcall(_getRootCompoundWidget, ctrl) end
        if ok_root and root then
            local ok1 = pcall(function() root:SetVisible(v) end)
            if not ok1 then pcall(function() root:SetOpacity(v and 1.0 or 0.0) end) end
            n = n + 1
        end
    end
    dlog(string.format("[HeadTracking:NPAnchor] setNameplatesHidden(%s) applied to %d root(s)", tostring(hidden), n))
end

--- Suppress (or restore) all crosshair/bracket writes. With writes off, the
--- game positions the crosshair tree natively. If the lock-on box then sits ON
--- the enemy under head movement, our root-margin shove was the drift source
--- and the fix is CET-only (move the dot child, not the box). If the box is
--- still off, it is a genuine separate-camera projection (native hook needed).
---   GetMod("HeadTracking").DiagCrosshairSuppress(true)   -- stop writing
---   GetMod("HeadTracking").DiagCrosshairSuppress(false)  -- resume
function BuiltinCrosshair:setCrosshairSuppress(on)
    self._suppress_writes = on and true or false
    dlog(string.format("[HeadTracking:Reticle] crosshair writes %s",
        self._suppress_writes and "SUPPRESSED" or "ACTIVE"))
end

-- Recursive tree dump: name, visibility, translation, size, margin per node.
local function _dumpWidgetTree(widget, depth, max_depth)
    if widget == nil or depth > max_depth then return end
    local name = "?"
    pcall(function()
        local n = widget:GetName()
        name = (Game and Game.NameToString and Game.NameToString(n)) or tostring(n)
    end)
    local vis = "?"
    pcall(function() vis = tostring(widget:IsVisible()) end)
    local tx, ty = 0, 0
    pcall(function() local t = widget:GetTranslation(); tx, ty = t.X or t.x or 0, t.Y or t.y or 0 end)
    local mw, mh = 0, 0
    pcall(function() local s = widget:GetSize(); mw, mh = s.X or s.x or 0, s.Y or s.y or 0 end)
    local ml, mt = 0, 0
    pcall(function() local m = widget:GetMargin(); ml, mt = m.left or 0, m.top or 0 end)
    dlog(string.format("[HeadTracking:Tree] %s'%s' vis=%s trans=(%.0f,%.0f) size=(%.0f,%.0f) margin=(%.0f,%.0f)",
        string.rep("  ", depth), name, vis, tx, ty, mw, mh, ml, mt))
    local ok_n, n = pcall(function() return widget:GetNumChildren() end)
    if ok_n and type(n) == "number" and n > 0 then
        for i = 0, n - 1 do
            local ok_c, child = pcall(function() return widget:GetWidgetByIndex(i) end)
            if ok_c and child ~= nil then
                _dumpWidgetTree(child, depth + 1, max_depth)
            end
        end
    end
end

--- One-shot full widget-tree dump of every tracked crosshair controller. Run
--- while locked onto an enemy so the lock-on box is live in the tree; we read
--- the dump to identify the box widget by name.
---   GetMod("HeadTracking").DiagCrosshairTree()
function BuiltinCrosshair:dumpCrosshairTree()
    dlog(string.format("[HeadTracking:Tree] ===== crosshair tree dump (%d controller(s)) =====", #self.controllers))
    for i = 1, #self.controllers do
        local entry = self.controllers[i]
        dlog(string.format("[HeadTracking:Tree] controller[%d] class=%s", i, tostring(entry.class)))
        local ok_root, root
        if entry.using_compound then
            ok_root, root = pcall(_getRootCompoundWidget, entry.ctrl)
        else
            ok_root, root = pcall(_getRootWidget, entry.ctrl)
        end
        if not ok_root or root == nil then
            ok_root, root = pcall(_getRootCompoundWidget, entry.ctrl)
        end
        if ok_root and root then
            _dumpWidgetTree(root, 0, 10)
        else
            dlog("[HeadTracking:Tree]   root unavailable")
        end
    end
    dlog("[HeadTracking:Tree] ===== end crosshair tree dump =====")
end

-- Per-frame probe: for each crosshair controller, log head yaw alongside the
-- ROOT widget's margin + translation - the exact handle our SetMargin clobbers.
-- Run with writes SUPPRESSED (our reset zeroes the root once, so any non-zero
-- value afterwards is the GAME writing it). A root whose margin tracks head yaw
-- is the enemy-projected lock-on box's controller; roots that stay at (0,0) are
-- screen-locked (dot/reticle) and correctly need our offset.
function BuiltinCrosshair:_probeCrosshairMotionTick()
    self._ch_probe_frames = self._ch_probe_frames - 1
    self._ch_probe_log_ctr = (self._ch_probe_log_ctr or 0) + 1
    if (self._ch_probe_log_ctr % 6) ~= 0 then return end
    local yaw, pitch = self.camera:getRenderedYPR(0)
    for i = 1, #self.controllers do
        local entry = self.controllers[i]
        local ok_root, root
        if entry.using_compound then
            ok_root, root = pcall(_getRootCompoundWidget, entry.ctrl)
        else
            ok_root, root = pcall(_getRootWidget, entry.ctrl)
        end
        if not ok_root or root == nil then ok_root, root = pcall(_getRootCompoundWidget, entry.ctrl) end
        if ok_root and root then
            local rtx, rty = 0, 0
            pcall(function() local t = root:GetTranslation(); rtx, rty = t.X or t.x or 0, t.Y or t.y or 0 end)
            local rml, rmt = 0, 0
            pcall(function() local m = root:GetMargin(); rml, rmt = m.left or 0, m.top or 0 end)
            local rname = "?"
            pcall(function()
                local n = root:GetName()
                rname = (Game and Game.NameToString and Game.NameToString(n)) or tostring(n)
            end)
            -- The roots stay at (0,0); the enemy projection is carried by a
            -- deep child. Report the most-displaced descendant so we can see
            -- which controller has a child that tracks head yaw (= the box).
            local best = _maxTranslationWidget(root, 0, 8, nil)
            dlog(string.format(
                "[HeadTracking:CHMotion] ctrl[%d] class=%s yaw=%.1f pitch=%.1f | root '%s' margin=(%.1f,%.1f) trans=(%.1f,%.1f) | maxchild '%s' trans=(%.1f,%.1f)",
                i, tostring(entry.class), yaw, pitch, rname, rml, rmt, rtx, rty,
                best and best.name or "?", best and best.tx or 0, best and best.ty or 0))
        end
    end
end

--- Arm the per-frame crosshair-motion probe for `seconds` (default 6). Run with
--- writes suppressed and locked onto an enemy, then pan the head left/right.
---   GetMod("HeadTracking").DiagCrosshairMotion(6)
function BuiltinCrosshair:probeCrosshairMotion(seconds)
    local s = (type(seconds) == "number" and seconds > 0) and seconds or 6
    self._ch_probe_frames = math.floor(s * 60)
    self._ch_probe_log_ctr = 0
    dlog(string.format("[HeadTracking:CHMotion] armed for ~%ds (%d frames)", s, self._ch_probe_frames))
end

-- Per-write log of the lock-on gate decision. Throttled (only on frames where
-- _gate_log_now is set) so all widgets log together on the same frame. Logs the
-- current margin, the value we last wrote, our intended offset, and whether the
-- gate concluded the engine is driving the widget (= locked, we backed off).
function BuiltinCrosshair:_gateLog(label, cur_l, cur_t, child_mag, store, intended_x, intended_y, reason)
    if not self._gate_log_now then return end
    local verdict = "OURS (shove to body-fwd)"
    if reason == "margin" then
        verdict = string.format("ENGINE/margin (leave, static=%.2fs)",
            store.static_since and (os.clock() - store.static_since) or 0)
    end
    if reason == "lock-child" then verdict = "ENGINE/lock-child (leave)" end
    dlog(string.format(
        "[HeadTracking:Gate] %-28s cur=(%.1f,%.1f) childTrans=%.1f lastWrote=(%s,%s) intended=(%.1f,%.1f) -> %s",
        tostring(label), cur_l, cur_t, child_mag,
        store.l and string.format("%.1f", store.l) or "nil",
        store.t and string.format("%.1f", store.t) or "nil",
        intended_x, intended_y, verdict))
end

--- Arm the lock-on gate log for `seconds` (default 8). Run in a car with a
--- weapon drawn, head panned off-centre: free-aim should report OURS for the
--- bracket/dot widgets; locking an enemy should flip the lock-on widget to
--- ENGINE while the dot stays OURS.
---   GetMod("HeadTracking").DiagGate(8)
function BuiltinCrosshair:probeGate(seconds)
    local s = (type(seconds) == "number" and seconds > 0) and seconds or 8
    self._gate_log_frames = math.floor(s * 60)
    self._gate_log_ctr = 0
    dlog(string.format("[HeadTracking:Gate] armed for ~%ds (%d frames)", s, self._gate_log_frames))
end

-- Collect every VISIBLE widget in a subtree as { name, tx, ty } rows. No name
-- or translation gate: the on-hit "plink" may be centred and plainly named, so
-- the probe relies on first-seen-name dedup (in _probeHitMarkerTick) rather
-- than a filter to keep the always-present reticle parts from spamming.
local function _collectVisibleWidgets(widget, depth, max_depth, out)
    if widget == nil or depth > max_depth then return end
    local vis = false
    pcall(function() vis = widget:IsVisible() and true or false end)
    if vis then
        local name = "?"
        pcall(function()
            local n = widget:GetName()
            name = (Game and Game.NameToString and Game.NameToString(n)) or tostring(n)
        end)
        local tx, ty = 0, 0
        pcall(function() local t = widget:GetTranslation(); tx, ty = t.X or t.x or 0, t.Y or t.y or 0 end)
        out[#out + 1] = { name = name, tx = tx, ty = ty }
    end
    local ok_n, n = pcall(function() return widget:GetNumChildren() end)
    if ok_n and type(n) == "number" and n > 0 then
        for i = 0, n - 1 do
            local ok_c, child = pcall(function() return widget:GetWidgetByIndex(i) end)
            if ok_c and child ~= nil then
                _collectVisibleWidgets(child, depth + 1, max_depth, out)
            end
        end
    end
end

-- Per-frame lock-signal discovery: for each crosshair controller, snapshot the
-- set of VISIBLE descendant widgets (by name) and log every one that APPEARS or
-- VANISHES vs the previous snapshot. A hard lock makes the lock-on rectangle's
-- widget(s) become visible (and unlock hides them), so locking/unlocking an
-- enemy prints a clear +APPEAR / -VANISH pair that names the widget we should
-- gate on. Throttled to ~every 6th frame. Read-only; never writes.
-- (Defined after _collectVisibleWidgets so that local is in lexical scope.)
function BuiltinCrosshair:_probeLockTick()
    self._lock_probe_frames = self._lock_probe_frames - 1
    self._lock_probe_ctr = (self._lock_probe_ctr or 0) + 1
    if (self._lock_probe_ctr % 6) ~= 0 then return end
    self._lock_prev_vis = self._lock_prev_vis or {}
    for i = 1, #self.controllers do
        local entry = self.controllers[i]
        local root = self:_resolveRoot(entry)
        if root ~= nil then
            local out = {}
            _collectVisibleWidgets(root, 0, 10, out)
            local cur = {}
            for j = 1, #out do cur[out[j].name] = out[j] end
            local key = "ctrl[" .. i .. "]"
            local prev = self._lock_prev_vis[key] or {}
            for name, w in pairs(cur) do
                if not prev[name] then
                    dlog(string.format("[HeadTracking:Lock] %s %-22s +APPEAR  trans=(%.1f,%.1f)",
                        key, "'" .. name .. "'", w.tx, w.ty))
                end
            end
            for name in pairs(prev) do
                if not cur[name] then
                    dlog(string.format("[HeadTracking:Lock] %s %-22s -VANISH", key, "'" .. name .. "'"))
                end
            end
            self._lock_prev_vis[key] = cur
        end
    end
end

--- Arm the lock-signal discovery log for `seconds` (default 12). Run it, then:
--- spend a few seconds in free aim, then put the reticle on an enemy until it
--- locks (the rectangle appears), then break the lock. The +APPEAR line that
--- coincides with the lock naming the rectangle widget is the gate signal.
---   GetMod("HeadTracking").DiagLockSignal(12)
function BuiltinCrosshair:probeLockSignal(seconds)
    local s = (type(seconds) == "number" and seconds > 0) and seconds or 12
    self._lock_probe_frames = math.floor(s * 60)
    self._lock_probe_ctr = 0
    self._lock_prev_vis = {}
    dlog(string.format("[HeadTracking:Lock] armed for ~%ds (%d frames); controllers=%d. Free-aim, then lock an enemy, then break lock.",
        s, self._lock_probe_frames, #self.controllers))
end

-- Resolve a controller entry's root widget (root or compound fallback).
function BuiltinCrosshair:_resolveRoot(entry)
    local ok_root, root
    if entry.using_compound then
        ok_root, root = pcall(_getRootCompoundWidget, entry.ctrl)
    else
        ok_root, root = pcall(_getRootWidget, entry.ctrl)
    end
    if not ok_root or root == nil then ok_root, root = pcall(_getRootCompoundWidget, entry.ctrl) end
    if ok_root then return root end
    return nil
end

-- Per-frame probe (throttled every 3rd frame). Scans every captured crosshair
-- controller AND every captured hit/kill marker controller. For each, logs the
-- root margin we wrote alongside each visible widget the FIRST time its name
-- appears during the armed window. The always-present reticle parts log once; a
-- transient on-hit marker logs when it pops, with its translation and owning
-- controller. If a marker pops under a controller whose rootMargin is ~0 while
-- ours is off-centre, that controller's root is one we are not yet shoving.
function BuiltinCrosshair:_probeHitMarkerTick()
    self._hm_probe_frames = self._hm_probe_frames - 1
    self._hm_probe_log_ctr = (self._hm_probe_log_ctr or 0) + 1
    if (self._hm_probe_log_ctr % 3) ~= 0 then return end
    self._hm_seen = self._hm_seen or {}

    local function scan(entry, idx_label)
        local root = self:_resolveRoot(entry)
        if root == nil then return end
        local rml, rmt = 0, 0
        pcall(function() local m = root:GetMargin(); rml, rmt = m.left or 0, m.top or 0 end)
        local out = {}
        _collectVisibleWidgets(root, 0, 10, out)
        for j = 1, #out do
            local w = out[j]
            local key = idx_label .. "|" .. w.name
            if not self._hm_seen[key] then
                self._hm_seen[key] = true
                dlog(string.format(
                    "[HeadTracking:HitMarker] %s %s | rootMargin=(%.0f,%.0f) | NEW '%s' trans=(%.1f,%.1f)",
                    idx_label, tostring(entry.class), rml, rmt, w.name, w.tx, w.ty))
            end
        end
    end

    for i = 1, #self.controllers do scan(self.controllers[i], "ctrl[" .. i .. "]") end
    for i = 1, #self.hit_markers do scan(self.hit_markers[i], "marker[" .. i .. "]") end
end

--- Arm the hit-marker discovery probe for `seconds` (default 10). Run with
--- normal writes active, head turned off-centre, then shoot an enemy several
--- times. Each visible widget logs once (first appearance) so a transient
--- on-hit plink stands out from the always-present reticle parts.
---   GetMod("HeadTracking").DiagHitMarker(10)
function BuiltinCrosshair:probeHitMarker(seconds)
    local s = (type(seconds) == "number" and seconds > 0) and seconds or 10
    self._hm_probe_frames = math.floor(s * 60)
    self._hm_probe_log_ctr = 0
    self._hm_seen = {}
    dlog(string.format("[HeadTracking:HitMarker] armed for ~%ds (%d frames). markers=%d. Turn head off-centre and fire at an enemy repeatedly.",
        s, self._hm_probe_frames, #self.hit_markers))
end

--- Start the read-probe for `seconds` of gameplay (default 6s @ 60fps).
--- Run from the console while locked onto an enemy, then move your HEAD:
---   GetMod("HeadTracking").DiagNameplateProbe()
function BuiltinCrosshair:probeNameplates(seconds)
    local s = (type(seconds) == "number" and seconds > 0) and seconds or 6
    self._np_probe_frames = math.floor(s * 60)
    self._np_probe_log_ctr = 0
    dlog(string.format("[HeadTracking:Nameplate] probe armed for %.0f frames; live nameplates=%d. Move your HEAD now.",
        self._np_probe_frames, #self.nameplates))
end

-- Depth-capped tree dump that ALSO reports each widget's render-transform
-- translation and visibility, so we can spot which widget is actually drawn
-- offset on the locked enemy (the blue lock box) vs. the centred reticle.
-- Read-only; only safe against a fully-built tree (call from console, in game).
local function _dumpTree(widget, depth, max_depth)
    if widget == nil or depth > max_depth then return end
    local name, cls, vis, tx, ty = "?", "?", "?", 0, 0
    pcall(function()
        local n = widget:GetName()
        name = (Game and Game.NameToString and Game.NameToString(n)) or tostring(n)
    end)
    pcall(function()
        local c = widget:GetClassName()
        cls = (Game and Game.NameToString and Game.NameToString(c)) or tostring(c)
    end)
    pcall(function() vis = tostring(widget:IsVisible()) end)
    pcall(function() local t = widget:GetTranslation(); tx, ty = t.X or t.x or 0, t.Y or t.y or 0 end)
    dlog(string.format("[HeadTracking:Reticle:TREE] %s%s  <%s>  vis=%s trans=(%.0f,%.0f)",
        string.rep("  ", depth), name, cls, vis, tx, ty))
    local ok_n, n = pcall(function() return widget:GetNumChildren() end)
    if ok_n and type(n) == "number" and n > 0 then
        for i = 0, n - 1 do
            local ok_c, child = pcall(function() return widget:GetWidgetByIndex(i) end)
            if ok_c and child ~= nil then _dumpTree(child, depth + 1, max_depth) end
        end
    end
end

--- Dump every captured controller's widget tree. Run from the console while
--- locked onto an enemy so the blue lock box is live:
---   GetMod("HeadTracking").DiagDumpTrees()
function BuiltinCrosshair:dumpAllTrees()
    dlog("[HeadTracking:Reticle:TREE] ====== DUMP ALL CONTROLLER TREES ======")
    for i = 1, #self.controllers do
        local e = self.controllers[i]
        dlog(string.format("[HeadTracking:Reticle:TREE] --- controller[%d] %s ---", i, e.class))
        local ok_root, root
        if e.using_compound then ok_root, root = pcall(_getRootCompoundWidget, e.ctrl)
        else ok_root, root = pcall(_getRootWidget, e.ctrl) end
        if ok_root and root then _dumpTree(root, 0, 6) else dlog("[HeadTracking:Reticle:TREE]   (root unavailable)") end
    end
    dlog("[HeadTracking:Reticle:TREE] ====== END DUMP ======")
end

-- Find the first descendant widget with the given name (depth-first), capped
-- at max_depth so a malformed/cyclic tree can't run the Lua stack off a cliff
-- and hard-crash the engine. Must only be called against a fully-built tree
-- (steady state) - walking during OnInitialize can hand back half-constructed
-- child pointers that fault natively past any pcall guard.
local function _findWidgetByName(widget, target, max_depth)
    if widget == nil or (max_depth ~= nil and max_depth < 0) then return nil end
    local this_name
    pcall(function()
        local n = widget:GetName()
        this_name = (Game and Game.NameToString and Game.NameToString(n)) or tostring(n)
    end)
    if this_name == target then return widget end
    local ok_n, n = pcall(function() return widget:GetNumChildren() end)
    if ok_n and type(n) == "number" and n > 0 then
        local next_depth = max_depth ~= nil and (max_depth - 1) or nil
        for i = 0, n - 1 do
            local ok_c, child = pcall(function() return widget:GetWidgetByIndex(i) end)
            if ok_c and child ~= nil then
                local found = _findWidgetByName(child, target, next_depth)
                if found ~= nil then return found end
            end
        end
    end
    return nil
end

-- The bracket/reticle canvases inside the DriverCombat HUD tree. They are
-- siblings directly under the HUD root (alongside vehicles_startup, Flair,
-- etc.), so there's no shared parent to move without dragging the whole HUD -
-- we move each. Which is visible depends on weapon/vehicle (_v2 is the current
-- design, plain is legacy, _trail is the trailing-animation layer); moving a
-- hidden one is harmless. The dot is a separate gameuiCrosshairBaseGameController
-- already handled by the main controller path. Discovered via widget-tree dump.
local DRIVER_COMBAT_BRACKETS_WIDGETS = {
    "crosshair_brackets",
    "crosshair_brackets_v2",
    "crosshair_brackets_trail",
}

function BuiltinCrosshair:_installObservers()
    if self._observed then return end
    self._observed = true

    local this_self = self
    -- The two base classes plus every CONCRETE per-weapon controller.
    --
    -- Binding only the bases was the bug behind "the shotgun reticle unsticks".
    -- CET reports what actually happened:
    --   Function OnUpdate in class gameuiCrosshairBaseGameController does not exist
    --   Function OnUpdate in class gameuiCrosshairContainerController does not exist
    --   Function OnBulletSpreadChanged in class gameuiCrosshairContainerController does not exist
    --   Function OnCurrentRaycastTarget ... does not exist
    --   Function UpdateCrosshairState ... does not exist
    -- Those methods are declared on the concrete controllers, not on the bases,
    -- so every per-frame and recapture observer silently bound to nothing. A
    -- controller whose handle went stale was therefore never re-adopted, and we
    -- kept writing a dead handle's root while the live reticle rode the head.
    -- OnBulletSpreadChanged is the shotgun's own hook, which is why the shotgun
    -- is the weapon that shows it.
    --
    -- Names taken from the game's script table; tryBind logs and skips any that
    -- a future patch removes, so listing one that does not exist costs a line
    -- in the diag log and nothing else.
    -- CrosshairGameControllerPersistentDot is deliberately NOT here. It draws
    -- the game's persistent dot, which is a separate always-on element rather
    -- than the weapon reticle. Adding it made us shove that dot to the aim
    -- offset, which showed up in play as a stray blue dot sitting where the
    -- offset pointed. It was never tracked before and does not need to be.
    local classes = {
        'gameuiCrosshairBaseGameController',
        'gameuiCrosshairContainerController',
        'CrosshairGameController',
        'CrosshairGameController_Basic',
        'CrosshairGameController_BlackwallForce',
        'CrosshairGameController_Hercules',
        'CrosshairGameController_Jailbreak_Power',
        'CrosshairGameController_Jailbreak_Smart',
        'CrosshairGameController_Jailbreak_Tech',
        'CrosshairGameController_Launcher',
        'CrosshairGameController_Mantis_Blade',
        'CrosshairGameController_Melee',
        'CrosshairGameController_NoWeapon',
        'CrosshairGameController_Rasetsu',
        'CrosshairGameController_Simple',
        'CrosshairGameController_Smart_Rifl',
        'CrosshairGameController_Tech_Hex',
        'CrosshairGameController_Tech_Round',
    }

    -- Driver-combat HUD controller. Its crosshair_brackets_trail child draws
    -- the in-car bracket reticle and is not a standalone crosshair controller,
    -- so the main controller path never moves it. Resolve that child on
    -- capture and SetMargin it by the same offset as the dot each frame.
    -- Both spellings. The game's script table calls it
    -- DriverCombatHUDGameController with no gameui prefix, and CET reported
    -- "Function OnUninitialize in class gameuiDriverCombatHUDGameController
    -- does not exist" for the prefixed one. tryBind logs and skips whichever is
    -- not present on this build, so trying both costs a diag line.
    for _, dc_cls in ipairs({ 'DriverCombatHUDGameController',
                              'gameuiDriverCombatHUDGameController' }) do
    tryBind('ObserveAfter', dc_cls, 'OnInitialize', function(this)
        local ok_root, root = pcall(_getRootCompoundWidget, this)
        if not ok_root or root == nil then
            ok_root, root = pcall(_getRootWidget, this)
        end
        local found = {}
        if ok_root and root then
            for _, name in ipairs(DRIVER_COMBAT_BRACKETS_WIDGETS) do
                local w = _findWidgetByName(root, name, 8)
                if w ~= nil then found[#found + 1] = w end
            end
        end
        this_self.dc_brackets = found
        dlog(string.format("[HeadTracking:Reticle] driver-combat brackets acquired: %d/%d",
            #found, #DRIVER_COMBAT_BRACKETS_WIDGETS))
    end)
    tryBind('Observe', dc_cls, 'OnUninitialize', function()
        this_self.dc_brackets = nil
        -- Drop every per-widget gate latch on vehicle-HUD teardown. See
        -- _resetGateState for the failure mode this prevents (post-dismount
        -- "stuck-at-centre" reticle from a stale lock-child latch).
        this_self:_resetGateState()
    end)
    end

    -- Belt-and-suspenders: the engine fires this on the VehicleComponent before
    -- the DriverCombat HUD tears down. Resetting the gate state here too means
    -- the very first on-foot frame after dismount starts from a clean slate,
    -- even if the HUD-controller observer lags. The method name carries the
    -- Event suffix; without it CET reported "does not exist" and this bound to
    -- nothing.
    tryBind('Observe', 'VehicleComponent', 'OnVehicleStartedUnmountingEvent', function()
        this_self:_resetGateState()
    end)

    -- NPC nameplate (the lock-on box). Capture instances so the read-probe
    -- can inspect where the game positions them each frame. Read-only.
    tryBind('ObserveAfter', 'gameuiNpcNameplateGameController', 'OnInitialize', function(this)
        this_self:_trackNameplate(this)
    end)
    tryBind('Observe', 'gameuiNpcNameplateGameController', 'OnUninitialize', function(this)
        this_self:_untrackNameplate(this)
    end)

    -- On-hit / on-kill markers own separate HUD roots. Capture the damage
    -- event's world hit point and keep those roots projected onto it.
    for _, cls in ipairs(HIT_MARKER_CLASSES) do
        tryBind('ObserveAfter', cls, 'OnInitialize', function(this)
            this_self:_trackHitMarker(cls, this)
        end)
        tryBind('Observe', cls, 'OnUninitialize', function(this)
            this_self:_untrackHitMarker(this)
        end)
    end
    tryBind('ObserveAfter', 'TargetHitIndicatorGameController', 'OnDamageAdded',
        function()
            this_self:_writeHitMarkersAtAim()
        end)
    tryBind('ObserveAfter', 'TargetHitIndicatorGameController', 'OnKillAdded', function()
        this_self:_writeHitMarkersAtAim()
    end)
    tryBind('ObserveAfter', 'TargetHitIndicatorGameController', 'PlayAnimation', function()
        this_self:_writeHitMarkersAtAim()
    end)
    tryBind('ObserveAfter', 'TargetHitIndicatorGameController', 'OnSway', function()
        this_self:_writeHitMarkersAtAim()
    end)
    tryBind('ObserveAfter', 'TargetHitIndicatorGameController', 'UpdateWidgetPosition', function()
        this_self:_writeHitMarkersAtAim()
    end)
    tryBind('ObserveAfter', 'TargetHitIndicatorGameController', 'OnNormalizeAndSaveSwayEvent', function()
        this_self:_writeHitMarkersAtAim()
    end)

    -- Crosshair controllers are captured at OnInitialize, which only fires when
    -- the HUD spawns. Reload the mod mid-session (or start it late) and those
    -- controllers are already live, so nothing is ever captured and the module
    -- silently does nothing until the next load screen. These three run on a
    -- live controller during ordinary play - a raycast target changing, weapon
    -- spread changing, the crosshair state changing - so an already-running
    -- HUD is adopted within a second of moving or looking around. _track
    -- de-duplicates by handle, so the repeat calls cost one list scan.
    -- These fire many times a second, and the handle they hand us does NOT
    -- compare equal to a previously captured one, so _track's de-duplication
    -- cannot see it is the same controller: routing them through _track grew
    -- the list without bound (3 roots to 204 in six seconds) and stuttered the
    -- game. _adopt keeps ONE entry per class and swaps the handle in place.
    local RECAPTURE_METHODS = {
        'OnCurrentRaycastTarget',
        'OnBulletSpreadChanged',
        'UpdateCrosshairState',
    }
    for _, cls in ipairs(classes) do
        for _, method in ipairs(RECAPTURE_METHODS) do
            tryBind('Observe', cls, method, function(this)
                this_self:_adopt(cls, this)
            end)
        end
    end

    for _, cls in ipairs(classes) do
        tryBind('Observe', cls, 'OnInitialize', function(this)
            this_self._stat.observe_fired = this_self._stat.observe_fired + 1
            this_self:_track(cls, this, 'Observe/OnInitialize')
        end)
        tryBind('ObserveAfter', cls, 'OnInitialize', function(this)
            this_self._stat.observe_after_fired = this_self._stat.observe_after_fired + 1
            this_self:_track(cls, this, 'ObserveAfter/OnInitialize')
        end)
        tryBind('Observe', cls, 'OnUninitialize', function(this)
            this_self:_untrack(this)
        end)
        -- No OnUpdate observer. CET's scripting.log says the method exists on
        -- none of these classes, base or concrete:
        --   Function OnUpdate in class CrosshairGameController_Basic does not exist
        --   ... and the same for all 17 of them plus both bases.
        -- It never fired, so the per-frame write it appeared to provide was
        -- always coming from tick() -> _writeOffset alone. Binding it only
        -- produced a CET error per class per session.
    end

    dlog("[HeadTracking:Reticle] observer install pass complete")
end

function BuiltinCrosshair:_findEntry(this)
    for i = 1, #self.controllers do
        if self.controllers[i].ctrl == this then return self.controllers[i] end
    end
    return nil
end
function BuiltinCrosshair:_getAimDistance(player)
    if not Game then return nil end

    local now = os.clock()

    local targeting = Game.GetTargetingSystem and Game.GetTargetingSystem()
    local spatial = Game.GetSpatialQueriesSystem and Game.GetSpatialQueriesSystem()
    if not player or not targeting or not spatial then
        self._aim_distance = nil
        self._aim_distance_sample_t = nil
        return nil
    end

    local ok_crosshair, from, forward = pcall(_getCrosshairData, targeting, player)
    if not ok_crosshair or not from or not forward then
        if not self._aim_distance_error_logged then
            self._aim_distance_error_logged = true
            dlog("[HeadTracking:Reticle] aim-distance crosshair query failed: " ..
                tostring(from))
        end
        self._aim_distance = nil
        self._aim_distance_sample_t = nil
        return nil
    end

    local camera_system = Game.GetCameraSystem and Game.GetCameraSystem()
    local ok_sway, sway = pcall(_getNormalizedWeaponSway)
    if not camera_system or not ok_sway or not sway then
        self._aim_distance = nil
        self._aim_distance_sample_t = nil
        return nil
    end
    local projected = camera_system:ProjectPoint(Vector4.new(
        from.x + forward.x * 10,
        from.y + forward.y * 10,
        from.z + forward.z * 10,
        from.w))
    local sway_x = sway.X or sway.x
    local sway_y = sway.Y or sway.y
    if not projected or type(sway_x) ~= "number" or type(sway_y) ~= "number" then
        self._aim_distance = nil
        self._aim_distance_sample_t = nil
        return nil
    end
    local aim_point = camera_system:UnprojectPoint(
        Vector2.new(projected.x + sway_x, projected.y - sway_y))
    if not aim_point then
        self._aim_distance = nil
        self._aim_distance_sample_t = nil
        return nil
    end
    local aim_x = aim_point.x - from.x
    local aim_y = aim_point.y - from.y
    local aim_z = aim_point.z - from.z
    local forward_length = math.sqrt(
        aim_x * aim_x + aim_y * aim_y + aim_z * aim_z)
    if forward_length <= 0 or forward_length ~= forward_length then
        self._aim_distance = nil
        self._aim_distance_sample_t = nil
        return nil
    end
    local ray_x = aim_x / forward_length
    local ray_y = aim_y / forward_length
    local ray_z = aim_z / forward_length
    local to = Vector4.new(
        from.x + ray_x * AIM_RAY_LENGTH_M,
        from.y + ray_y * AIM_RAY_LENGTH_M,
        from.z + ray_z * AIM_RAY_LENGTH_M,
        from.w)
    local ok_raycast, hit, result = pcall(_raycastStatic, spatial, from, to)
    if ok_raycast and not hit then
        ok_raycast, hit, result = pcall(_raycastWorldStatic, spatial, from, to)
    end
    if not ok_raycast then
        if not self._aim_distance_error_logged then
            self._aim_distance_error_logged = true
            dlog("[HeadTracking:Reticle] aim-distance raycast failed: " ..
                tostring(hit))
        end
        self._aim_distance = nil
        self._aim_distance_sample_t = nil
        return nil
    end

    local hit_position = hit and result and result.position
    if not hit_position then
        self._aim_distance = nil
        self._aim_distance_sample_t = nil
        return nil
    end

    local hit_x = hit_position.x - from.x
    local hit_y = hit_position.y - from.y
    local hit_z = hit_position.z - from.z
    local hit_distance = math.sqrt(hit_x * hit_x + hit_y * hit_y + hit_z * hit_z)
    if hit_distance <= 0 or hit_distance ~= hit_distance then
        self._aim_distance = nil
        self._aim_distance_sample_t = nil
        return nil
    end

    local previous = self._aim_distance
    local previous_t = self._aim_distance_sample_t
    if not previous or not previous_t then
        self._aim_distance = hit_distance
    else
        local dt = now - previous_t
        local alpha = 1.0 - math_exp(-AIM_DISTANCE_SMOOTH_SPEED * dt)
        self._aim_distance = previous + (hit_distance - previous) * alpha
    end
    self._aim_distance_sample_t = now
    self._aim_distance_error_logged = false
    return self._aim_distance
end

--- Return the live distance used for positional parallax. Nil means the aim ray
--- missed.
--- @return number|nil
function BuiltinCrosshair:getAimDistance()
    local player = Game and Game.GetPlayer and Game.GetPlayer()
    local distance = self:_getAimDistance(player)
    return distance
end


-- Where to put the reticle on the frames _computeOffset calls invalid, which is
-- when the aim direction has left the view entirely (its dot with camera
-- forward goes non-positive, at full pitch or a hard turn).
--
-- Doing nothing on those frames is what made the reticle come unstuck: tick()
-- returned before writing, every reticle kept its last margin, and a margin
-- that stops being updated is a reticle glued to the screen and riding the
-- head. AGENTS.md names this case and gives two acceptable answers, hide or
-- clamp to the screen edge.
--
-- This hides, by sending it well off screen along the last valid direction.
-- Clamping it to the edge instead was tried and reverted: an aim point that
-- has left the view has no on-screen position, so parking a marker at the
-- boundary pins it there while the world keeps moving underneath, which reads
-- as the reticle coming unstuck the moment it touches the edge. Off screen is
-- also continuous with the valid path, where a far-off-centre aim point is
-- already heading out of frame under its own projection.
local OFFSCREEN_REACH = 4.0
local function _offscreenOffset(last_dx, last_dy, screen_w, screen_h)
    local len = math_sqrt(last_dx * last_dx + last_dy * last_dy)
    if len < 1e-3 then return nil, nil end
    local reach = (screen_w > screen_h and screen_w or screen_h) * OFFSCREEN_REACH
    return last_dx / len * reach, last_dy / len * reach
end

function BuiltinCrosshair:_computeOffset(screen_w, screen_h)
    local player = Game and Game.GetPlayer and Game.GetPlayer()
    local targeting = player and Game.GetTargetingSystem and Game.GetTargetingSystem()
    local camera_system = Game and Game.GetCameraSystem and Game.GetCameraSystem()
    if not player or not targeting or not camera_system then return 0, 0, false end

    local ok_crosshair, from, forward = pcall(_getCrosshairData, targeting, player)
    if not ok_crosshair or not from or not forward then return 0, 0, false end

    local camera_forward = camera_system:GetActiveCameraForward()
    if forward.x * camera_forward.x + forward.y * camera_forward.y
            + forward.z * camera_forward.z <= 0 then
        return 0, 0, false
    end

    local point = Vector4.new(
        from.x + forward.x * 10,
        from.y + forward.y * 10,
        from.z + forward.z * 10,
        from.w)
    local projected = camera_system:ProjectPoint(point)
    if not projected or projected.x ~= projected.x or projected.y ~= projected.y then
        return 0, 0, false
    end

    local ok_sway, sway = pcall(_getNormalizedWeaponSway)
    if not ok_sway or not sway then return 0, 0, false end
    local sway_x = sway.X or sway.x
    local sway_y = sway.Y or sway.y
    if type(sway_x) ~= "number" or type(sway_y) ~= "number" then
        return 0, 0, false
    end

    -- Returned unclamped. When the aim point is off screen the reticle belongs
    -- off screen with it; holding it at the boundary would put a marker
    -- somewhere the rounds are not going.
    return (projected.x + sway_x) * screen_w * 0.5,
        (-projected.y + sway_y) * screen_h * 0.5, true
end

--- Write offset to the crosshair widget. Margin-on-root is the single 1× path
--- (root.SetTranslation was a second contributor that previously doubled the
--- motion). Gated by _engineDriving: if the engine is projecting this widget
--- onto a locked target this frame, we leave it alone so the box stays on the
--- enemy; otherwise we shove it by the head offset to mark body-forward.
-- One line, once per session, the first time a crosshair sits gated off long
-- enough to be visibly stuck while the intended offset moves under it. Silent
-- on a healthy install: a normal hold lasts GATE_STALE_SECONDS and resets.
function BuiltinCrosshair:_reportStuckHold(entry, dx, dy, cur_l, cur_t)
    local now = os.clock()
    if not entry._stuck_since then
        entry._stuck_since = now
        entry._stuck_dx, entry._stuck_dy = dx, dy
        return
    end
    if self._stuck_reported then return end
    if (now - entry._stuck_since) < GATE_STUCK_SECONDS then return end
    local moved = math_abs(dx - (entry._stuck_dx or dx))
                + math_abs(dy - (entry._stuck_dy or dy))
    if moved < GATE_STUCK_INTENDED_PX then return end

    self._stuck_reported = true
    htlog(string.format(
        "[HeadTracking:Reticle] %s has been left to the engine for %.1fs while the aim " ..
        "offset moved %.0fpx, so it is riding the head instead of the world. " ..
        "margin=(%.1f,%.1f) lastWrote=(%s,%s) intended=(%.1f,%.1f) screen=%dx%d",
        tostring(entry.class), now - entry._stuck_since, moved,
        cur_l, cur_t,
        entry._lw and entry._lw.l and string.format("%.1f", entry._lw.l) or "nil",
        entry._lw and entry._lw.t and string.format("%.1f", entry._lw.t) or "nil",
        dx, dy, self._stat_screen_w or 0, self._stat_screen_h or 0))
end

function BuiltinCrosshair:_writeOne(entry, dx, dy, seen)
    if not entry or not entry.ctrl then return end
    local ctrl = entry.ctrl
    self._stat.write_attempts = self._stat.write_attempts + 1

    local ok_root, root
    if entry.using_compound then
        ok_root, root = pcall(_getRootCompoundWidget, ctrl)
    else
        ok_root, root = pcall(_getRootWidget, ctrl)
    end
    if not ok_root or root == nil then
        self._stat.last_error = "root nil at write time"
        return
    end

    -- Already shoved this frame through another entry. tostring on the widget
    -- userdata is address-based, so it identifies the widget itself rather than
    -- the handle we happened to reach it through.
    if seen then
        local key = tostring(root)
        if seen[key] then return end
        seen[key] = true
    end

    entry._lw = entry._lw or {}
    local log_armed = self._gate_log_frames and self._gate_log_frames > 0
    local reason, cur_l, cur_t, child_mag = _engineDriving(root, entry._lw, log_armed, dx, dy)
    if USE_LOCK_CHILD_GATE then
        local locked, lock_mag = _lockStateFromVisibleChanges(root, entry._lw, cur_l, cur_t)
        if locked then
            reason = "lock-child"
            child_mag = lock_mag
        end
    end
    if log_armed then
        self:_gateLog(entry.class, cur_l, cur_t, child_mag, entry._lw, dx, dy, reason)
    end

    if reason == "lock-child" then
        local ok_m, err_m = pcall(_rootSetMargin, root,
            inkMargin.new({ left = 0, top = 0, right = 0, bottom = 0 }))
        if ok_m then
            entry.set_margin_ok = true
            entry._lw.l, entry._lw.t = 0, 0
        else
            entry.set_margin_ok = false
            self._stat.last_error = "SetMargin lock clear: " .. tostring(err_m)
        end
        return
    end

    -- Engine projects this widget via its own root margin: leave it entirely.
    if reason == "margin" then
        entry.set_margin_ok = true
        self:_reportStuckHold(entry, dx, dy, cur_l, cur_t)
        return
    end
    entry._stuck_since = nil

    -- Position only. This module must never touch a crosshair's VISIBILITY.
    --
    -- An earlier attempt hid the root when the aim point projected off screen,
    -- which looked reasonable and was not: visibility is the game's to manage,
    -- and it hides the crosshair itself for aiming down sights among other
    -- things. Once we had hidden a root we also had to un-hide it, and that
    -- un-hide fired on a widget the game had meanwhile hidden for its own
    -- reasons, forcing the dot back on screen during ADS. Writing the offset is
    -- enough on its own: an off-screen aim point puts the widget off screen.
    local ok_m, err_m = pcall(_rootSetMargin, root,
        inkMargin.new({ left = dx, top = dy, right = 0, bottom = 0 }))
    if ok_m then
        self._stat.write_root_margin_ok = self._stat.write_root_margin_ok + 1
        entry.set_margin_ok = true
        -- Record what LANDED, not what was asked for. The two differ once the
        -- offset is large enough that the widget's layout bounds it, which is
        -- exactly when the reticle reaches a screen edge. Storing the intended
        -- value there makes the next frame's `is_ours` test compare our
        -- unbounded request against the engine's bounded result, fail, and hand
        -- the widget to the hold branch on every single frame. The widget is
        -- then never written again and rides the head: a reticle that starts
        -- drifting the moment it touches the edge and does not recover. Reading
        -- back costs one GetMargin per write and makes the comparison honest.
        local got_l, got_t = dx, dy
        pcall(function()
            local m = root:GetMargin()
            got_l, got_t = m.left or dx, m.top or dy
        end)
        entry._lw.l, entry._lw.t = got_l, got_t
    else
        entry.set_margin_ok = false
        self._stat.last_error = "SetMargin: " .. tostring(err_m)
    end
end

-- One shove per ROOT WIDGET per frame.
--
-- Entries are per controller, and several controllers resolve to the same root:
-- the tree is rediscovered during play and the same controller comes back with
-- a handle that does not compare equal, so it is tracked again (a live capture
-- showed roots=17 for a handful of real controllers). Shoving each entry
-- separately then applies the offset to that widget more than once and it lands
-- at a multiple of the intended position: further from centre than the reticle,
-- along the same direction. That is what the stray persistent dot was doing,
-- sitting out at the far offset instead of on the reticle.
--
-- This is the same footgun the bracket path and _writeOne already warn about
-- ("translation + margin = 2x"), reached by a different route.
function BuiltinCrosshair:_writeOffset(dx, dy)
    -- Isolation diagnostic: when _shove_only_idx is set, only that controller
    -- gets the offset; the rest are written with (0,0) so they sit where the
    -- game placed them. Lets us SEE which controller's shove drags the
    -- world-projected lock-on box off the enemy. nil = normal (shove all).
    local only = self._shove_only_idx
    local entries = self:_entries()
    local seen = {}
    for i = 1, #entries do
        if only == nil or i == only then
            self:_writeOne(entries[i], dx, dy, seen)
        else
            self:_writeOne(entries[i], 0, 0, seen)
        end
    end
end

--- Isolation toggle: shove ONLY controller `idx` (1..N), reset the rest. Turn
--- your head so there's a visible offset, then cycle idx 1..N and watch which
--- one makes the lock-on box leave the enemy. idx 0/nil restores normal.
---   GetMod("HeadTracking").DiagShoveOnly(4)
function BuiltinCrosshair:setShoveOnly(idx)
    local entries = self:_entries()
    if type(idx) == "number" and idx >= 1 and idx <= #entries then
        self._shove_only_idx = idx
        local entry = entries[idx]
        local names = {}
        local ok_root, root
        if entry.using_compound then
            ok_root, root = pcall(_getRootCompoundWidget, entry.ctrl)
        else
            ok_root, root = pcall(_getRootWidget, entry.ctrl)
        end
        if ok_root and root then
            local ok_n, n = pcall(function() return root:GetNumChildren() end)
            if ok_n and type(n) == "number" then
                for i = 0, math.min(n - 1, 15) do
                    pcall(function()
                        local c = root:GetWidgetByIndex(i)
                        local nm = c and c:GetName()
                        names[#names + 1] = (Game and Game.NameToString and Game.NameToString(nm)) or tostring(nm)
                    end)
                end
            end
        end
        dlog(string.format("[HeadTracking:ShoveOnly] idx=%d class=%s children=[%s]",
            idx, tostring(entry.class), table.concat(names, ",")))
    else
        self._shove_only_idx = nil
        dlog("[HeadTracking:ShoveOnly] cleared (normal shove restored)")
    end
end

-- Move the in-car bracket group (crosshair_brackets_trail) by the same offset
-- as the dot, so the rectangle corners follow the head-tracked aim point
-- instead of staying pinned to screen centre. Each bracket canvas is gated by
-- _engineDriving (same as the dot): when a target is locked the engine projects
-- the rectangle onto the enemy itself, so we back off and leave it; when free
-- it sits at centre and we shove it to body-forward.
function BuiltinCrosshair:_writeBrackets(dx, dy)
    local list = self.dc_brackets
    if list == nil then return end
    -- SetMargin only - same 1x path as the dot. Applying SetTranslation as
    -- well stacked a second offset on these canvases, doubling the motion
    -- (the "translation + margin = 2x" footgun; see _writeOne). Applied to
    -- every bracket canvas; the visible one moves, hidden ones are no-ops.
    local s = self.bracket_scale
    local mx, my = dx * s, dy * s
    self._bracket_lw = self._bracket_lw or {}
    for i = 1, #list do
        local store = self._bracket_lw[i]
        if store == nil then store = {}; self._bracket_lw[i] = store end
        local log_armed = self._gate_log_frames and self._gate_log_frames > 0
        local reason, cur_l, cur_t, child_mag = _engineDriving(list[i], store, log_armed, mx, my)
        if USE_LOCK_CHILD_GATE then
            local locked, lock_mag = _lockStateFromVisibleChanges(list[i], store, cur_l, cur_t)
            if locked then
                reason = "lock-child"
                child_mag = lock_mag
            end
        end
        if log_armed then
            self:_gateLog("brackets[" .. i .. "]", cur_l, cur_t, child_mag, store, mx, my, reason)
        end
        if reason == "lock-child" then
            local ok_m, err_m = pcall(_rootSetMargin, list[i],
                inkMargin.new({ left = 0, top = 0, right = 0, bottom = 0 }))
            if ok_m then
                store.l, store.t = 0, 0
            elseif not self._brackets_margin_err_logged then
                self._brackets_margin_err_logged = true
                dlog("[HeadTracking:Reticle] brackets lock-clear SetMargin FAILED: " .. tostring(err_m))
            end
        elseif reason ~= "margin" then
            local ok_m, err_m = pcall(_rootSetMargin, list[i],
                inkMargin.new({ left = mx, top = my, right = 0, bottom = 0 }))
            if ok_m then
                store.l, store.t = mx, my
            elseif not self._brackets_margin_err_logged then
                self._brackets_margin_err_logged = true
                dlog("[HeadTracking:Reticle] brackets SetMargin FAILED: " .. tostring(err_m))
            end
        end
    end
end

local function _widgetName(w)
    local name = nil
    pcall(function()
        local n = w:GetName()
        name = (Game and Game.NameToString and Game.NameToString(n)) or tostring(n)
    end)
    return name
end

-- A smart-weapon target bracket, identified by the pooled widget's library
-- name first (cheap) and by its logic controller class second. Which one hits
-- is latched per session in _smart_find_mode so the steady-state rescan only
-- pays for the check that actually works.
local function _isSmartBucket(w, by_controller)
    if not by_controller then
        return _widgetName(w) == SMART_BUCKET_WIDGET_NAME
    end
    local matched = false
    pcall(function()
        local c = _widgetGetController(w)
        matched = c ~= nil and c:IsA(SMART_BUCKET_CONTROLLER)
    end)
    return matched
end

local function _collectSmartBuckets(widget, depth, by_controller, out)
    if widget == nil or depth > SMART_WALK_DEPTH then return end
    -- depth 0 is a root we shove, never a bracket. A bracket's own children
    -- ride with it, so the walk stops there.
    if depth > 0 and _isSmartBucket(widget, by_controller) then
        out[#out + 1] = widget
        return
    end
    local ok_n, n = pcall(_getNumChildren, widget)
    if not ok_n or type(n) ~= "number" then return end
    for i = 0, n - 1 do
        local ok_c, child = pcall(_getWidgetByIndex, widget, i)
        if ok_c and child ~= nil then
            _collectSmartBuckets(child, depth + 1, by_controller, out)
        end
    end
end

--- Rebuild the list of smart-weapon target brackets living under the roots we
--- shove. Walking from those roots (rather than from a separately captured
--- smart controller) is what guarantees the list is exactly the set of
--- brackets our offset reaches, whichever root carries the shove.
function BuiltinCrosshair:_refreshSmartBuckets()
    local out = {}
    local entries = self:_entries()
    for i = 1, #entries do
        local root = self:_resolveRoot(entries[i])
        if root ~= nil then
            _collectSmartBuckets(root, 0, self._smart_find_mode == 'controller', out)
        end
    end
    -- Nothing by name: retry once by logic-controller class and latch whichever
    -- identifies the pool, so a renamed library item still resolves.
    if #out == 0 and self._smart_find_mode == nil then
        for i = 1, #entries do
            local root = self:_resolveRoot(entries[i])
            if root ~= nil then _collectSmartBuckets(root, 0, true, out) end
        end
        if #out > 0 then
            self._smart_find_mode = 'controller'
            dlog("[HeadTracking:Reticle] smart target brackets found by controller class")
            slog(string.format("discovery: %d bracket(s) by controller class", #out))
        end
    elseif #out > 0 and self._smart_find_mode == nil then
        self._smart_find_mode = 'name'
        dlog("[HeadTracking:Reticle] smart target brackets found by widget name")
        slog(string.format("discovery: %d bracket(s) by widget name", #out))
    end
    self._smart_buckets = out
end

--- Which of the bracket's two position channels the engine drives. Whichever
--- one MOVES while we are not writing it is the engine's; we take the other, so
--- our cancellation and the engine's projection never fight over one value.
--- Returns 'margin' or 'translation' (the channel WE take), or nil while the
--- brackets have not moved far enough yet to tell.
function BuiltinCrosshair:_detectSmartChannel(list)
    local first = self._smart_probe
    if first == nil then first = {}; self._smart_probe = first end
    for i = 1, #list do
        local w = list[i]
        local l, t = 0, 0
        pcall(function() local m = w:GetMargin(); l, t = m.left or 0, m.top or 0 end)
        local tx, ty = 0, 0
        pcall(function() local v = w:GetTranslation(); tx, ty = v.X or v.x or 0, v.Y or v.y or 0 end)
        local seen = first[i]
        if seen == nil then
            first[i] = { l = l, t = t, tx = tx, ty = ty }
        else
            if math_abs(l - seen.l) > SMART_CHANNEL_MOVE_PX or
               math_abs(t - seen.t) > SMART_CHANNEL_MOVE_PX then
                return 'translation'
            end
            if math_abs(tx - seen.tx) > SMART_CHANNEL_MOVE_PX or
               math_abs(ty - seen.ty) > SMART_CHANNEL_MOVE_PX then
                return 'margin'
            end
        end
    end
    return nil
end

--- One line describing a bracket as the engine currently has it: what it is,
--- and where each of its two position channels sits.
local function _smartWidgetLine(i, w)
    local ctrl_class = "?"
    pcall(function()
        local c = _widgetGetController(w)
        if c ~= nil then ctrl_class = tostring(c:GetClassName()) end
    end)
    local l, t = 0, 0
    pcall(function() local m = w:GetMargin(); l, t = m.left or 0, m.top or 0 end)
    local tx, ty = 0, 0
    pcall(function() local v = w:GetTranslation(); tx, ty = v.X or v.x or 0, v.Y or v.y or 0 end)
    local vis = false
    pcall(function() vis = w:IsVisible() and true or false end)
    local kids = 0
    pcall(function() kids = w:GetNumChildren() or 0 end)
    -- Where the match sits in the tree. A match that is an ANCESTOR of the
    -- reticle cancels the shove for the whole crosshair, which is the reticle
    -- sitting at screen centre.
    local chain, node = {}, w
    for _ = 1, 6 do
        local parent = nil
        pcall(function() parent = node:GetParentWidget() end)
        if parent == nil then break end
        chain[#chain + 1] = tostring(_widgetName(parent))
        node = parent
    end
    return string.format(
        "  bracket[%d] name=%s ctrl=%s visible=%s children=%d margin=(%.1f,%.1f) translation=(%.1f,%.1f) parents=[%s]",
        i, tostring(_widgetName(w)), ctrl_class, tostring(vis), kids, l, t, tx, ty,
        table.concat(chain, "<"))
end

--- How many of OUR shoves a bracket actually inherits. The crosshair roots we
--- write are nested (the container root is an ancestor of the crosshair
--- controller's own root), so a bracket can sit under one, two, or none of
--- them, and cancelling a flat 1x leaves the rest of the drift in place. An
--- ancestor counts when its margin is the exact value we wrote this frame.
--- All brackets share the chain above smartGun, so this is computed once per
--- frame from the first one.
local function _inheritedShoveCount(w, dx, dy)
    local n, node = 0, w
    for _ = 1, SMART_WALK_DEPTH do
        local parent = nil
        pcall(function() parent = node:GetParentWidget() end)
        if parent == nil then break end
        local l, t = 0, 0
        pcall(function() local m = parent:GetMargin(); l, t = m.left or 0, m.top or 0 end)
        if math_abs(l - dx) < GATE_MATCH_EPS and math_abs(t - dy) < GATE_MATCH_EPS then
            n = n + 1
        end
        node = parent
    end
    return n
end

--- Cancel our body-forward shove on every smart-weapon target bracket, so each
--- one stays where the engine projected it: on its target.
function BuiltinCrosshair:_writeSmartTargets(dx, dy)
    local now = os.clock()
    if now - (self._smart_rescan_t or -1) >= SMART_RESCAN_SECONDS then
        self._smart_rescan_t = now
        self:_refreshSmartBuckets()
    end

    local list = self._smart_buckets or {}

    -- Probe before the empty-list return, so a scan that finds nothing is
    -- distinguishable in the log from the scan never running at all.
    if (self._smart_probe_left or 0) > 0 then
        if now - (self._smart_probe_t or -1) >= SMART_PROBE_INTERVAL_SECONDS then
            self._smart_probe_t = now
            self._smart_probe_left = self._smart_probe_left - 1
            local visible_count, placed_count = 0, 0
            for i = 1, #list do
                local vis = false
                pcall(function() vis = list[i]:IsVisible() and true or false end)
                if vis then visible_count = visible_count + 1 end
                local l, t = 0, 0
                pcall(function() local m = list[i]:GetMargin(); l, t = m.left or 0, m.top or 0 end)
                if math_abs(l) > 1.0 or math_abs(t) > 1.0 then placed_count = placed_count + 1 end
            end
            slog(string.format(
                "brackets=%d visible=%d placed=%d roots=%d chan=%s inherited=%s shove=(%.1f,%.1f)",
                #list, visible_count, placed_count, #self:_entries(),
                tostring(self._smart_chan), tostring(self._smart_inherited), dx, dy))
            local logged = 0
            for i = 1, #list do
                local vis = false
                pcall(function() vis = list[i]:IsVisible() and true or false end)
                local l, t = 0, 0
                pcall(function() local m = list[i]:GetMargin(); l, t = m.left or 0, m.top or 0 end)
                -- Log anything the engine has PLACED, visible or not: a bracket
                -- that keeps its projected margin while turning invisible is the
                -- engine hiding it (lock dropped or state changed); one that
                -- stays visible while its margin runs far off is ours drifting.
                if (vis or math_abs(l) > 1.0 or math_abs(t) > 1.0) and logged < 4 then
                    logged = logged + 1
                    slog(_smartWidgetLine(i, list[i]))
                end
            end
        end
    end

    if #list == 0 then return end

    if self._smart_chan == nil then
        self._smart_chan = self:_detectSmartChannel(list)
        if self._smart_chan == nil then return end
        self._smart_probe = nil
        dlog(string.format(
            "[HeadTracking:Reticle] smart target brackets: cancelling shove via %s",
            self._smart_chan))
        slog("channel decided: cancelling our shove via " .. self._smart_chan)
    end

    -- Zero shove reaching the brackets means nothing to cancel; writing -0
    -- would still be correct, but skipping keeps the idle path free.
    local inherited = _inheritedShoveCount(list[1], dx, dy)
    self._smart_inherited = inherited
    if inherited == 0 then return end

    local sx = -dx * inherited * self.smart_scale
    local sy = -dy * inherited * self.smart_scale
    for i = 1, #list do
        if self._smart_chan == 'translation' then
            pcall(_widgetSetTranslation, list[i], sx, sy)
        else
            pcall(_rootSetMargin, list[i],
                inkMargin.new({ left = sx, top = sy, right = 0, bottom = 0 }))
        end
    end
end

--- Scale applied to the smart-bracket cancellation. 1.0 cancels our shove
--- exactly, which is right when the bracket sits in the same coordinate space
--- as the root we shove. A scaled canvas in between would need the same kind of
--- factor the in-car brackets need (see bracket_scale).
---   GetMod("HeadTracking").DiagSmartScale(2.0)
function BuiltinCrosshair:setSmartScale(s)
    if type(s) == "number" and s == s then
        self.smart_scale = s
        dlog("[HeadTracking:Reticle] smart_scale = " .. tostring(s))
    end
    return self.smart_scale
end

--- One-shot dump of the smart-weapon bracket state: how many brackets are
--- live, which channel each one carries, and which channel we took. Run it with
--- a smart weapon up and a target locked.
---   GetMod("HeadTracking").DiagSmartTargets()
function BuiltinCrosshair:dumpSmartTargets()
    self:_refreshSmartBuckets()
    local list = self._smart_buckets or {}
    dlog(string.format(
        "==== [HeadTracking:Reticle] smart targets: %d bracket(s) find_mode=%s chan=%s scale=%.2f dx=%.1f dy=%.1f",
        #list, tostring(self._smart_find_mode), tostring(self._smart_chan),
        self.smart_scale, self._last_dx, self._last_dy))
    for i = 1, #list do
        local w = list[i]
        local l, t = 0, 0
        pcall(function() local m = w:GetMargin(); l, t = m.left or 0, m.top or 0 end)
        local tx, ty = 0, 0
        pcall(function() local v = w:GetTranslation(); tx, ty = v.X or v.x or 0, v.Y or v.y or 0 end)
        local vis = false
        pcall(function() vis = w:IsVisible() and true or false end)
        dlog(string.format("  bracket[%d] name=%s visible=%s margin=(%.1f,%.1f) translation=(%.1f,%.1f)",
            i, tostring(_widgetName(w)), tostring(vis), l, t, tx, ty))
    end
    dlog("============================================")
end

-- TEST: shove the captured nameplate roots by the dot offset, to confirm the
-- lock-on box rides on the nameplate controller. If the box moves toward the
-- enemy when this is on (head turned), the nameplate is the box's widget and we
-- refine to a proper per-target reprojection. Gated by _shove_nameplate.
function BuiltinCrosshair:_writeNameplates(dx, dy)
    for i = 1, #self.nameplates do
        local ctrl = self.nameplates[i]
        local ok_root, root = pcall(_getRootWidget, ctrl)
        if not ok_root or root == nil then ok_root, root = pcall(_getRootCompoundWidget, ctrl) end
        if ok_root and root then
            pcall(_rootSetMargin, root,
                inkMargin.new({ left = dx, top = dy, right = 0, bottom = 0 }))
        end
    end
end

function BuiltinCrosshair:_writeHitMarkers(dx, dy)
    for i = 1, #self.hit_markers do
        local entry = self.hit_markers[i]
        local root = self:_resolveRoot(entry)
        if root ~= nil then
            if entry.class == 'TargetHitIndicatorGameController' then
                local inverse_scale = Game.GetUISystem():GetInverseUIScale()
                local marker_dx = dx * inverse_scale
                local marker_dy = dy * inverse_scale
                local ok_reset, reset_error = pcall(_rootSetMargin, root,
                    inkMargin.new({ left = 0, top = 0, right = 0, bottom = 0 }))
                if not ok_reset then
                    error("[HeadTracking:HitMarker] root SetMargin reset failed: " ..
                        tostring(reset_error))
                end
                local ok_count, child_count = pcall(_getNumChildren, root)
                if not ok_count or type(child_count) ~= 'number' then
                    error("[HeadTracking:HitMarker] GetNumChildren failed: " ..
                        tostring(child_count))
                end
                for child_index = 0, child_count - 1 do
                    local ok_child, child = pcall(_getWidgetByIndex, root, child_index)
                    if not ok_child or child == nil then
                        error("[HeadTracking:HitMarker] GetWidgetByIndex failed at " ..
                            tostring(child_index))
                    end
                    local ok_write, write_error = pcall(_rootSetMargin, child,
                        inkMargin.new({ left = marker_dx, top = marker_dy, right = 0, bottom = 0 }))
                    if not ok_write then
                        error("[HeadTracking:HitMarker] child SetMargin failed: " ..
                            tostring(write_error))
                    end
                end
            else
                local ok_write, write_error = pcall(_rootSetMargin, root,
                    inkMargin.new({ left = dx, top = dy, right = 0, bottom = 0 }))
                if not ok_write then
                    error("[HeadTracking:HitMarker] SetMargin failed: " ..
                        tostring(write_error))
                end
            end
        end
    end
end

--- Diagnostic toggle for impact-point projection. Off leaves the marker where
--- the game draws it.
---   GetMod("HeadTracking").DiagShoveHitMarker(false)
function BuiltinCrosshair:setShoveHitMarker(on)
    self._shove_hitmarker = on and true or false
    if not self._shove_hitmarker then self:_writeHitMarkers(0, 0) end
    dlog(string.format("[HeadTracking:HitMarker] shove %s (live markers=%d)",
        self._shove_hitmarker and "ON" or "OFF", #self.hit_markers))
end

--- TEST toggle: ride the nameplate roots with the dot offset.
---   GetMod("HeadTracking").DiagShoveNameplate(true)
function BuiltinCrosshair:setShoveNameplate(on)
    self._shove_nameplate = on and true or false
    if not self._shove_nameplate then self:_writeNameplates(0, 0) end
    dlog(string.format("[HeadTracking:ShoveNameplate] %s (live nameplates=%d)",
        self._shove_nameplate and "ON" or "OFF", #self.nameplates))
end

-- Drop every gate hold-timer. Called wherever the driver stands down, because
-- the hold is measured in wall-clock seconds but _engineDriving only runs on
-- frames we actually write. A menu, a pause or a loading screen advances
-- os.clock without the gate observing anything, so a hold left running would
-- come back from a five-second map screen already past GATE_STALE_SECONDS and
-- take over an engine-owned margin it never watched.
function BuiltinCrosshair:_clearGateHolds()
    local entries = self:_entries()
    for i = 1, #entries do
        _clearHold(entries[i]._lw)
    end
    if self._bracket_lw then
        for i = 1, #self._bracket_lw do
            _clearHold(self._bracket_lw[i])
        end
    end
end

function BuiltinCrosshair:_resetAll()
    self._last_dx = 0
    self._last_dy = 0
    self:_writeOffset(0, 0)
    self:_writeBrackets(0, 0)
    self:_writeSmartTargets(0, 0)
    self:_writeHitMarkers(0, 0)
    if self._shove_nameplate then self:_writeNameplates(0, 0) end
end

--- Screen offset from centre to the true aim point, in pixels.
---
--- The one projection in this mod. ads_reticle draws its marker at this offset
--- rather than deriving its own, because two projections built from different
--- assumptions agree at small single-axis angles and drift apart on combined
--- poses - the failure AGENTS.md calls out under Reticle Compensation.
---
--- Computed fresh rather than served from `_last_dx`: tick() returns early
--- before computing anything when it has no controllers to write to, which is
--- exactly the state the game leaves it in with the sights up.
---
--- Deliberately independent of `crosshair_enabled`. That setting governs
--- whether this module moves the game's OWN reticle during normal play; the
--- ADS marker is a separate widget in a mode where the game draws no reticle
--- at all, and folding it in here would make ads_mode = "marker" silently
--- behave as "tracked".
--- @param screen_w number
--- @param screen_h number
--- @return number dx, number dy, boolean valid
function BuiltinCrosshair:getAimOffset(screen_w, screen_h)
    return self:_computeOffset(screen_w, screen_h)
end

function BuiltinCrosshair:tick(tracking_allowed)
    self._hit_marker_tracking_allowed = self.enabled and tracking_allowed
    if self._np_probe_frames > 0 then
        pcall(function() self:_probeNameplatesTick() end)
    end
    if self._ch_probe_frames > 0 then
        pcall(function() self:_probeCrosshairMotionTick() end)
    end
    if self._hm_probe_frames > 0 then
        pcall(function() self:_probeHitMarkerTick() end)
    end
    if self._lock_probe_frames > 0 then
        pcall(function() self:_probeLockTick() end)
    end
    if self._gate_log_frames > 0 then
        self._gate_log_frames = self._gate_log_frames - 1
        self._gate_log_ctr = (self._gate_log_ctr or 0) + 1
        self._gate_log_now = (self._gate_log_ctr % 6) == 0
    else
        self._gate_log_now = false
    end
    if self._suppress_writes then
        self:_clearGateHolds()
        if self._last_dx ~= 0 or self._last_dy ~= 0 then
            self:_resetAll()
        end
        return
    end
    if not self.enabled or not tracking_allowed then
        self:_clearGateHolds()
        if self._last_dx ~= 0 or self._last_dy ~= 0 then
            self:_resetAll()
        end
        return
    end
    local screen_w, screen_h = GetDisplayResolution()
    if not screen_w or screen_w <= 0 then
        screen_w, screen_h = 1920, 1080
    end
    self._stat_screen_w, self._stat_screen_h = screen_w, screen_h

    local dx, dy, valid = self:_computeOffset(screen_w, screen_h)

    self:_writeHitMarkersAtAim(dx, dy, valid)
    if #self:_entries() == 0 then
        self._stat.ticks_with_zero_ctrls = self._stat.ticks_with_zero_ctrls + 1
        return
    end

    if not valid then
        dx, dy = _offscreenOffset(self._last_dx, self._last_dy, screen_w, screen_h)
        if not dx then return end
    end

    self._last_dx = dx
    self._last_dy = dy
    self._stat.ticks_with_offset = self._stat.ticks_with_offset + 1
    self:_writeOffset(dx, dy)

    -- Lock-on handling is per-widget now (see _engineDriving / _writeOne /
    -- _writeBrackets): whether the dot, the on-foot box, or the in-car bracket
    -- rectangle, each widget the engine projects onto a locked target this
    -- frame is left untouched, and each one sitting idle at centre is shoved to
    -- body-forward. No global nameplate-count proxy - a stray pedestrian's
    -- nameplate no longer suppresses the free-aim compensation.
    self:_writeBrackets(dx, dy)
    -- Smart-weapon target brackets ride under a root we just shoved, and the
    -- engine has already projected each one onto its own target. Take our
    -- offset back off them.
    self:_writeSmartTargets(dx, dy)
    if self._shove_nameplate then self:_writeNameplates(dx, dy) end
end

--- Arm the smart-bracket probe for `seconds` of gameplay. Off by default.
---   GetMod("HeadTracking").DiagSmartProbe(20)
function BuiltinCrosshair:probeSmartTargets(seconds)
    local s = (type(seconds) == "number" and seconds > 0) and seconds or 20
    self._smart_probe_left = math.floor(s / SMART_PROBE_INTERVAL_SECONDS)
    self._smart_probe_t = nil
    dlog(string.format("[HeadTracking:Reticle] smart bracket probe armed for ~%ds (%d snapshots)",
        s, self._smart_probe_left))
end

function BuiltinCrosshair:setBracketScale(s)
    if type(s) == "number" and s == s then
        self.bracket_scale = s
        dlog("[HeadTracking:Reticle] bracket_scale = " .. tostring(s))
    end
    return self.bracket_scale
end

function BuiltinCrosshair:setEnabled(enabled)
    self.enabled = enabled and true or false
    if not self.enabled then self:_resetAll() end
end

function BuiltinCrosshair:isEnabled() return self.enabled end

function BuiltinCrosshair:dumpStatus()
    dlog("==== [HeadTracking:Reticle] status dump ====")
    dlog(string.format("  enabled=%s  live_ctrls=%d  hit_markers=%d  last_dx=%.1f last_dy=%.1f",
        tostring(self.enabled), #self.controllers, #self.hit_markers,
        self._last_dx, self._last_dy))
    for k, v in pairs(self._stat) do
        dlog(string.format("  %s = %s", k, tostring(v)))
    end
    for i, e in ipairs(self.controllers) do
        dlog(string.format(
            "  ctrl[%d] class=%s source=%s root_ok=%s using_compound=%s translation_ok=%s margin_ok=%s parent_ok=%s",
            i, e.class, tostring(e.source), tostring(e.root_ok),
            tostring(e.using_compound), tostring(e.set_translation_ok),
            tostring(e.set_margin_ok), tostring(e.parent_ok)))
    end
    dlog("============================================")
end

return BuiltinCrosshair
