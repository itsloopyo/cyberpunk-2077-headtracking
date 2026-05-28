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
local math_sin = math.sin
local math_cos = math.cos
local math_abs = math.abs
local math_atan = math.atan
local math_deg = math.deg

-- Hoisted pcall trampolines. The per-frame tick path reads cam.fov, cam.zoom,
-- calls GetRootWidget/GetRootCompoundWidget, and SetMargin under pcall. A
-- fresh `function() ... end` per call site allocates a closure each frame
-- per controller; module-scope helpers + pcall(_fn, args...) avoid that
-- without losing the error guard.
local function _readCamFov(cam) return cam.fov end
-- The cam.zoom FIELD is stale (always 1.0); cam:GetZoom() is the live ADS
-- magnification (e.g. 1.5 on an anti-armor weapon's ADS). Proven via the
-- DiagReticleFov probe. Zoom MAGNIFIES, so effective FOV = base_fov / zoom.
local function _readCamZoom(cam) return cam:GetZoom() end
local function _getRootWidget(ctrl) return ctrl:GetRootWidget() end
local function _getRootCompoundWidget(ctrl) return ctrl:GetRootCompoundWidget() end
local function _rootSetMargin(root, m) root:SetMargin(m) end
local function _widgetSetTranslation(widget, x, y)
    local ok = pcall(function() widget:SetTranslation(x, y) end)
    if ok then return true end
    ok = pcall(function() widget:SetTranslation(Vector2.new({ X = x, Y = y })) end)
    if ok then return true end
    ok = pcall(function() widget:SetTranslation(Vector2.new({ x = x, y = y })) end)
    if ok then return true end
    ok = pcall(function() widget:SetTranslation(inkVector2.new({ X = x, Y = y })) end)
    if ok then return true end
    return false
end
local function _widgetSetOffset(widget, x, y)
    pcall(_rootSetMargin, widget,
        inkMargin.new({ left = x, top = y, right = 0, bottom = 0 }))
    _widgetSetTranslation(widget, x, y)
end
local function _widgetSetHidden(widget, hidden)
    local visible = not hidden
    local ok = pcall(function() widget:SetVisible(visible) end)
    if not ok then
        pcall(function() widget:SetOpacity(visible and 1.0 or 0.0) end)
    end
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
local AIM_MARKER_DEPTH_M = 10.0
local LOCK_CHILD_TRANSLATION_PX = 8.0
-- The child-translation lock heuristic latches ANY visible descendant displaced
-- past LOCK_CHILD_TRANSLATION_PX as an "engine lock-on" and pins the reticle to
-- (0,0). A SHOTGUN's spread reticle has arms permanently displaced past that
-- threshold, so it false-fires and freezes the reticle at view-centre ("drifts
-- with the head"). Disabled: the margin-based _engineDriving signal still backs
-- off for a genuine root-margin lock projection, without the spread false-fire.
local USE_LOCK_CHILD_GATE = false

-- DebugLog is required lazily on first use so this module's file-scope is
-- side-effect free and cannot fail at require-time inside CET's sandbox.
local _debug_log_resolved = false
local _debug_log_write = nil
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

    -- Captured gameuiNpcNameplateGameController instances (the in-combat
    -- lock-on box). Read-only probe target: prior work proved writing their
    -- margin does nothing, but we never read back where the GAME places them
    -- each frame. _np_probe_frames > 0 enables the per-frame read logger.
    self.nameplates = {}
    -- Read-only probe targets: controllers that might draw the on-hit "plink"
    -- but are NOT crosshair controllers (so never written by _writeOffset).
    -- Populated by the DamageIndicator observer; scanned by the hit-marker probe.
    self.probe_extra = {}
    self._np_probe_frames = 0
    self._ch_probe_frames = 0
    self._hm_probe_frames = 0
    self._gate_log_frames = 0
    self._lock_probe_frames = 0

    self.fov_degrees = settings:get("crosshair_fov_degrees") or 84.0
    self.enabled = settings:get("crosshair_enabled")
    self.lead_factor = settings:get("crosshair_lead_factor") or 0.0

    self._last_dx = 0
    self._last_dy = 0

    -- Diagnostic: when true, tick() skips all crosshair/bracket writes so the
    -- game's native projection is left untouched. Used to decide whether the
    -- lock-on box drift is our own root-margin shove (box is a crosshair child
    -- the game already projects correctly through the head-rotated cam) versus
    -- a genuine separate-camera projection. Toggle via DiagCrosshairSuppress.
    self._suppress_writes = false
    self._suppress_hitmarker = true

    -- Scale factor applied to the in-car bracket offset. A margin unit on the
    -- DriverCombat bracket canvas is half a screen pixel (the dot's controller
    -- root is 1:1), so the dot's dx/dy under-moves the brackets by 2x. Tuned
    -- live to 2.0 via GetMod("HeadTracking").DiagBracketScale(n) and confirmed
    -- 1:1; the tuner stays exposed in case a different UI scale needs it.
    self.bracket_scale = 2.0

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
        elseif key == "crosshair_fov_degrees" then
            self.fov_degrees = settings:get("crosshair_fov_degrees") or 84.0
        elseif key == "crosshair_lead_factor" then
            self.lead_factor = settings:get("crosshair_lead_factor") or 0.0
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

function BuiltinCrosshair:_untrack(this)
    for i = #self.controllers, 1, -1 do
        if self.controllers[i].ctrl == this then
            dlog(string.format("[HeadTracking:Reticle] released (%s)",
                self.controllers[i].class))
            table.remove(self.controllers, i)
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
    for i = 1, #self.controllers do
        self.controllers[i]._lw = nil
    end
    self._bracket_lw = nil
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
local function _engineDriving(root, store, compute_child)
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
    if margin_off and not is_ours then
        return "margin", l, t, child_mag
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
    if reason == "margin" then verdict = "ENGINE/margin (leave)" end
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
-- controller AND every read-only probe_extra controller (DamageIndicator). For
-- each, logs the root margin we wrote alongside each visible widget the FIRST
-- time its name appears during the armed window. The always-present reticle
-- parts log once; a transient on-hit plink logs when it pops, with its trans
-- and owning controller. Read it like this: if the plink's controller is a
-- crosshair one whose rootMargin is our offset, the plink should follow us
-- (so it's likely a counter-centred child or a separate controller); if it's
-- DamageIndicator (or any non-crosshair controller, rootMargin ~0), that
-- controller's root is what we must shove by our offset.
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
    for i = 1, #self.probe_extra do scan(self.probe_extra[i], "extra[" .. i .. "]") end
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
    dlog(string.format("[HeadTracking:HitMarker] armed for ~%ds (%d frames). probe_extra=%d. Turn head off-centre and fire at an enemy repeatedly.",
        s, self._hm_probe_frames, #self.probe_extra))
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
    local classes = {
        'gameuiCrosshairBaseGameController',
        'gameuiCrosshairContainerController',
    }

    -- Driver-combat HUD controller. Its crosshair_brackets_trail child draws
    -- the in-car bracket reticle and is not a standalone crosshair controller,
    -- so the main controller path never moves it. Resolve that child on
    -- capture and SetMargin it by the same offset as the dot each frame.
    tryBind('ObserveAfter', 'gameuiDriverCombatHUDGameController', 'OnInitialize', function(this)
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
    tryBind('Observe', 'gameuiDriverCombatHUDGameController', 'OnUninitialize', function()
        this_self.dc_brackets = nil
        -- Drop every per-widget gate latch on vehicle-HUD teardown. See
        -- _resetGateState for the failure mode this prevents (post-dismount
        -- "stuck-at-centre" reticle from a stale lock-child latch).
        this_self:_resetGateState()
    end)

    -- Belt-and-suspenders: the engine fires OnVehicleStartedUnmounting on the
    -- VehicleComponent before the DriverCombat HUD tears down. Resetting the
    -- gate state here too means the very first on-foot frame after dismount
    -- starts from a clean slate, even if the HUD-controller observer lags.
    tryBind('Observe', 'VehicleComponent', 'OnVehicleStartedUnmounting', function()
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

    -- Damage indicator (candidate owner of the on-hit "plink"). Read-only
    -- probe target; never written. Tracked separately so _writeOffset leaves
    -- it alone while the hit-marker probe inspects it.
    tryBind('ObserveAfter', 'gameuiDamageIndicatorGameController', 'OnInitialize', function(this)
        for i = 1, #this_self.probe_extra do
            if this_self.probe_extra[i].ctrl == this then return end
        end
        this_self.probe_extra[#this_self.probe_extra + 1] =
            { ctrl = this, class = 'gameuiDamageIndicatorGameController' }
        dlog(string.format("[HeadTracking:HitMarker] DamageIndicator captured; probe_extra=%d", #this_self.probe_extra))
    end)
    tryBind('Observe', 'gameuiDamageIndicatorGameController', 'OnUpdate', function(this, dt)
        for i = 1, #this_self.probe_extra do
            if this_self.probe_extra[i].ctrl == this then
                if this_self._suppress_hitmarker then
                    this_self:_suppressHitMarker()
                end
                return
            end
        end
        this_self.probe_extra[#this_self.probe_extra + 1] =
            { ctrl = this, class = 'gameuiDamageIndicatorGameController' }
        if this_self._suppress_hitmarker then
            this_self:_suppressHitMarker()
        end
    end)
    tryBind('Observe', 'gameuiDamageIndicatorGameController', 'OnUninitialize', function(this)
        for i = #this_self.probe_extra, 1, -1 do
            if this_self.probe_extra[i].ctrl == this then table.remove(this_self.probe_extra, i) end
        end
    end)

    tryBind('ObserveAfter', 'gameuiDamageIndicatorPartLogicController', 'OnInitialize', function(this)
        for i = 1, #this_self.probe_extra do
            if this_self.probe_extra[i].ctrl == this then return end
        end
        this_self.probe_extra[#this_self.probe_extra + 1] =
            { ctrl = this, class = 'gameuiDamageIndicatorPartLogicController' }
        dlog(string.format("[HeadTracking:HitMarker] DamageIndicatorPart captured; probe_extra=%d", #this_self.probe_extra))
    end)
    tryBind('Observe', 'gameuiDamageIndicatorPartLogicController', 'OnUpdate', function(this, dt)
        for i = 1, #this_self.probe_extra do
            if this_self.probe_extra[i].ctrl == this then
                if this_self._suppress_hitmarker then
                    this_self:_suppressHitMarker()
                end
                return
            end
        end
        this_self.probe_extra[#this_self.probe_extra + 1] =
            { ctrl = this, class = 'gameuiDamageIndicatorPartLogicController' }
        if this_self._suppress_hitmarker then
            this_self:_suppressHitMarker()
        end
    end)
    tryBind('Observe', 'gameuiDamageIndicatorPartLogicController', 'OnUninitialize', function(this)
        for i = #this_self.probe_extra, 1, -1 do
            if this_self.probe_extra[i].ctrl == this then table.remove(this_self.probe_extra, i) end
        end
    end)

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
        tryBind('Observe', cls, 'OnUpdate', function(this, dt)
            this_self._stat.on_update_fired = this_self._stat.on_update_fired + 1
            -- Also ensure capture in case OnInitialize observer never fired
            this_self:_track(cls, this, 'Observe/OnUpdate')
            this_self:_writeOne(this_self:_findEntry(this), this_self._last_dx, this_self._last_dy)
        end)
    end

    dlog("[HeadTracking:Reticle] observer install pass complete")
end

function BuiltinCrosshair:_findEntry(this)
    for i = 1, #self.controllers do
        if self.controllers[i].ctrl == this then return self.controllers[i] end
    end
    return nil
end

function BuiltinCrosshair:_computeOffset(screen_w, screen_h)
    local yaw, pitch, roll = self.camera:getRenderedYPR(self.lead_factor)

    local h_fov_deg
    local player = Game and Game.GetPlayer and Game.GetPlayer()
    local cam = player and player:GetFPPCameraComponent()
    local vfov = nil
    if cam then
        local ok, raw = pcall(_readCamFov, cam)
        if ok and type(raw) == "number" and raw > 0 then
            local zoom = 1.0
            local zok, zraw = pcall(_readCamZoom, cam)
            if zok and type(zraw) == "number" and zraw > 0 then
                zoom = zraw
            end
            -- Zoom magnifies the view, so it NARROWS the FOV: divide, don't
            -- multiply. (Was `raw * zoom`, harmless only because the stale
            -- cam.zoom field was always 1.0; with live GetZoom()=1.5 on ADS
            -- the sign matters and `*` drifted the reticle.)
            vfov = raw / zoom
        end
    end
    if vfov then
        local aspect = screen_w / screen_h
        local tan_half_v = math_tan(math_rad(vfov) * 0.5)
        h_fov_deg = math_deg(2.0 * math_atan(tan_half_v * aspect))
    else
        h_fov_deg = self.fov_degrees
    end
    local v_fov_deg = math_deg(2.0 * math_atan(
        math_tan(math_rad(h_fov_deg) * 0.5) * (screen_h / screen_w)))

    local yaw_rad = math_rad(yaw)
    local pitch_rad = math_rad(pitch)
    local roll_rad = math_rad(-(roll or 0))

    local sy, cy = math_sin(yaw_rad), math_cos(yaw_rad)
    local sp, cp = math_sin(pitch_rad), math_cos(pitch_rad)

    local pos_x, pos_y, pos_z = 0, 0, 0
    if self.camera.getAppliedPosition then
        pos_x, pos_y, pos_z = self.camera:getAppliedPosition()
    end

    local x0 = -pos_x
    local y0 = -pos_z
    local z0 = AIM_MARKER_DEPTH_M - pos_y

    local x1 = x0 * cy + z0 * sy
    local z1 = -x0 * sy + z0 * cy
    local ax = x1
    local ay = y0 * cp + z1 * sp
    local az = -y0 * sp + z1 * cp

    if math_abs(roll_rad) > 1e-4 then
        local cr, sr = math_cos(roll_rad), math_sin(roll_rad)
        local rx = ax * cr - ay * sr
        local ry = ax * sr + ay * cr
        ax, ay = rx, ry
    end

    local tan_half_h = math_tan(math_rad(h_fov_deg) * 0.5)
    local tan_half_v = math_tan(math_rad(v_fov_deg) * 0.5)

    if math_abs(az) <= 1e-3 or tan_half_h <= 1e-3 or tan_half_v <= 1e-3 then
        return 0, 0, false
    end

    local dx = (ax / az) / tan_half_h * (screen_w * 0.5)
    local dy = (ay / az) / tan_half_v * (screen_h * 0.5)

    if dx ~= dx or dy ~= dy then return 0, 0, false end
    if math_abs(dx) > 1e6 or math_abs(dy) > 1e6 then return 0, 0, false end

    -- B2 diagnostic: log the raw FOV/zoom the projection used, so we can learn
    -- CP2077's zoom convention (does scope zoom multiply or divide the FOV?) and
    -- fix the zoomed-weapon reticle drift correctly instead of guessing.
    if self._fov_log_frames and self._fov_log_frames > 0 then
        self._fov_log_frames = self._fov_log_frames - 1
        self._fov_log_ctr = (self._fov_log_ctr or 0) + 1
        if (self._fov_log_ctr % 15) == 0 then
            -- cam.fov / cam.zoom are blind to ADS (proven: constant 51/1.0).
            -- Probe candidate live-FOV sources so one ADS capture reveals which
            -- one actually tracks the zoom; then the projection uses that.
            local function rd(fn) local ok, v = pcall(fn); if ok and type(v) == "number" then return v end return nil end
            local function fmt(v) return v and string.format("%.2f", v) or "nil" end
            local f  = rd(function() return cam and cam.fov end)
            local z  = rd(function() return cam and cam.zoom end)
            local fc = rd(function() return cam and cam.fieldOfView end)
            local gf = rd(function() return cam and cam:GetFOV() end)
            local gz = rd(function() return cam and cam:GetZoom() end)
            local player = Game and Game.GetPlayer and Game.GetPlayer()
            local csys = rd(function() return Game.GetCameraSystem and Game.GetCameraSystem():GetActiveCameraFOV() end)
            local pfov = rd(function() return player and player:GetFPPCameraComponent() and player:GetFPPCameraComponent():GetFOV() end)
            dlog(string.format(
                "[ReticleFov] fov=%s zoom=%s fieldOfView=%s GetFOV=%s GetZoom=%s camSysFOV=%s pGetFOV=%s | yaw=%.1f dx=%.0f",
                fmt(f), fmt(z), fmt(fc), fmt(gf), fmt(gz), fmt(csys), fmt(pfov), yaw, dx))
        end
    end

    return dx, dy, true
end

--- Write offset to the crosshair widget. Margin-on-root is the single 1× path
--- (root.SetTranslation was a second contributor that previously doubled the
--- motion). Gated by _engineDriving: if the engine is projecting this widget
--- onto a locked target this frame, we leave it alone so the box stays on the
--- enemy; otherwise we shove it by the head offset to mark body-forward.
function BuiltinCrosshair:_writeOne(entry, dx, dy)
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

    entry._lw = entry._lw or {}
    local log_armed = self._gate_log_frames and self._gate_log_frames > 0
    local reason, cur_l, cur_t, child_mag = _engineDriving(root, entry._lw, log_armed)
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
        return
    end

    local ok_m, err_m = pcall(_rootSetMargin, root,
        inkMargin.new({ left = dx, top = dy, right = 0, bottom = 0 }))
    if ok_m then
        self._stat.write_root_margin_ok = self._stat.write_root_margin_ok + 1
        entry.set_margin_ok = true
        entry._lw.l, entry._lw.t = dx, dy
    else
        entry.set_margin_ok = false
        self._stat.last_error = "SetMargin: " .. tostring(err_m)
    end
end

function BuiltinCrosshair:_writeOffset(dx, dy)
    -- Isolation diagnostic: when _shove_only_idx is set, only that controller
    -- gets the offset; the rest are written with (0,0) so they sit where the
    -- game placed them. Lets us SEE which controller's shove drags the
    -- world-projected lock-on box off the enemy. nil = normal (shove all).
    local only = self._shove_only_idx
    for i = 1, #self.controllers do
        if only == nil or i == only then
            self:_writeOne(self.controllers[i], dx, dy)
        else
            self:_writeOne(self.controllers[i], 0, 0)
        end
    end
end

--- Isolation toggle: shove ONLY controller `idx` (1..N), reset the rest. Turn
--- your head so there's a visible offset, then cycle idx 1..N and watch which
--- one makes the lock-on box leave the enemy. idx 0/nil restores normal.
---   GetMod("HeadTracking").DiagShoveOnly(4)
function BuiltinCrosshair:setShoveOnly(idx)
    if type(idx) == "number" and idx >= 1 and idx <= #self.controllers then
        self._shove_only_idx = idx
        local entry = self.controllers[idx]
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
        local reason, cur_l, cur_t, child_mag = _engineDriving(list[i], store, log_armed)
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

-- Collect all descendants whose name equals `target` into `out` (depth-capped).
local function _collectByName(widget, target, depth, max_depth, out)
    if widget == nil or depth > max_depth then return end
    local name
    pcall(function()
        local n = widget:GetName()
        name = (Game and Game.NameToString and Game.NameToString(n)) or tostring(n)
    end)
    if name == target then out[#out + 1] = widget end
    local ok_n, n = pcall(function() return widget:GetNumChildren() end)
    if ok_n and type(n) == "number" and n > 0 then
        for i = 0, n - 1 do
            local ok_c, child = pcall(function() return widget:GetWidgetByIndex(i) end)
            if ok_c and child ~= nil then
                _collectByName(child, target, depth + 1, max_depth, out)
            end
        end
    end
end

-- Shove the on-hit confirmation container by the dot offset. Depending on HUD
-- state it can live under a crosshair controller or the damage-indicator
-- controller, and it does not inherit the crosshair root margin.
function BuiltinCrosshair:_writeHitMarker(dx, dy)
    local function writeEntry(entry, write_root)
        local root = self:_resolveRoot(entry)
        if root ~= nil then
            if write_root then
                _widgetSetOffset(root, dx, dy)
            end
            local found = {}
            _collectByName(root, "root", 0, 10, found)
            for j = 1, #found do
                _widgetSetOffset(found[j], dx, dy)
            end
        end
    end
    for i = 1, #self.controllers do
        writeEntry(self.controllers[i], false)
    end
    for i = 1, #self.probe_extra do
        writeEntry(self.probe_extra[i], true)
    end
end

function BuiltinCrosshair:_suppressHitMarker()
    local function hideEntry(entry)
        local root = self:_resolveRoot(entry)
        if root ~= nil then
            local found = {}
            _collectByName(root, "root", 0, 10, found)
            for j = 1, #found do
                _widgetSetHidden(found[j], true)
            end
        end
    end
    for i = 1, #self.probe_extra do
        hideEntry(self.probe_extra[i])
    end
end

--- Diagnostic toggle for the on-hit 'root' confirmation widget offset.
---   GetMod("HeadTracking").DiagShoveHitMarker(true)
function BuiltinCrosshair:setShoveHitMarker(on)
    self._suppress_hitmarker = not on
    if self._suppress_hitmarker then self:_suppressHitMarker() end
    dlog(string.format("[HeadTracking:HitMarker] stock plink %s", self._suppress_hitmarker and "suppressed" or "visible"))
end

--- TEST toggle: ride the nameplate roots with the dot offset.
---   GetMod("HeadTracking").DiagShoveNameplate(true)
function BuiltinCrosshair:setShoveNameplate(on)
    self._shove_nameplate = on and true or false
    if not self._shove_nameplate then self:_writeNameplates(0, 0) end
    dlog(string.format("[HeadTracking:ShoveNameplate] %s (live nameplates=%d)",
        self._shove_nameplate and "ON" or "OFF", #self.nameplates))
end

function BuiltinCrosshair:_resetAll()
    self._last_dx = 0
    self._last_dy = 0
    self:_writeOffset(0, 0)
    self:_writeBrackets(0, 0)
    if self._suppress_hitmarker then self:_suppressHitMarker() end
    if self._shove_nameplate then self:_writeNameplates(0, 0) end
end

function BuiltinCrosshair:tick(tracking_allowed)
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
        if self._last_dx ~= 0 or self._last_dy ~= 0 then
            self:_resetAll()
        end
        return
    end
    if not self.enabled or not tracking_allowed then
        if self._last_dx ~= 0 or self._last_dy ~= 0 then
            self:_resetAll()
        end
        return
    end
    if #self.controllers == 0 then
        self._stat.ticks_with_zero_ctrls = self._stat.ticks_with_zero_ctrls + 1
        return
    end

    local screen_w, screen_h = GetDisplayResolution()
    if not screen_w or screen_w <= 0 then
        screen_w, screen_h = 1920, 1080
    end

    local dx, dy, valid = self:_computeOffset(screen_w, screen_h)
    if not valid then return end

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
    if self._shove_nameplate then self:_writeNameplates(dx, dy) end
    if self._suppress_hitmarker then self:_suppressHitMarker() end
end

--- Arm the FOV/zoom diagnostic for `seconds` (default 8). Run it, then aim
--- down sights / scope a weapon and swing your head: the [ReticleFov] lines
--- show the fov/zoom the projection used vs the head yaw and resulting dx, so
--- we can see whether scope zoom should multiply or divide the FOV.
---   GetMod("HeadTracking").DiagReticleFov(8)
function BuiltinCrosshair:probeReticleFov(seconds)
    local s = (type(seconds) == "number" and seconds > 0) and seconds or 8
    local ok, DebugLog = pcall(require, "modules/debuglog")
    if ok and DebugLog and DebugLog.setEnabled then DebugLog.setEnabled(true) end
    self._fov_log_frames = math.floor(s * 120)
    self._fov_log_ctr = 0
    dlog(string.format("[ReticleFov] armed ~%ds. ADS/scope a weapon and swing your head now.", s))
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
    dlog(string.format("  enabled=%s  live_ctrls=%d  last_dx=%.1f last_dy=%.1f",
        tostring(self.enabled), #self.controllers, self._last_dx, self._last_dy))
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
