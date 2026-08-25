-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- State-gate self-test. Runnable under stock lua (no CET sandbox).
--
-- Covers the stale-latch failure that silently killed head tracking mid
-- session: GameUI's isMenu/isScene flags are set by paired observer edges,
-- and when the game re-creates a menu controller without tearing the old one
-- down (applying graphics or audio settings does this) the close edge never
-- arrives. The gate then reported "menu open" forever and only a mod reload
-- brought tracking back.

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("FAIL %s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

local function assert_true(v, label)
    if not v then error("FAIL " .. label .. ": expected truthy, got " .. tostring(v), 2) end
end

local function assert_false(v, label)
    if v then error("FAIL " .. label .. ": expected falsy, got " .. tostring(v), 2) end
end

-- gamePSMUpperBodyStates.Aim, mirrored from state.lua.
local PSM_UPPERBODY_AIM = 6

-- Live game state the blackboard stubs read. Tests mutate this directly.
local live = { has_player = true, in_menu = false, scene_tier = 1, upper_body = 0,
               chase_camera = false }

local observers = {}
local cet_events = {}

function registerForEvent(name, fn) cet_events[name] = fn end
function Observe(class, method, fn) observers[class .. "." .. method] = fn end
ObserveAfter = Observe

local blackboard_defs = {
    UI_System = { IsInMenu = "IsInMenu" },
    PlayerStateMachine = { UpperBody = "UpperBody", SceneTier = "SceneTier",
                           IsVehicleInTPP = "IsVehicleInTPP" },
}
function GetAllBlackboardDefs() return blackboard_defs end

local ui_blackboard = { GetBool = function(_, _) return live.in_menu end }
local psm_blackboard = {
    GetBool = function(_, key)
        if key == blackboard_defs.PlayerStateMachine.IsVehicleInTPP then
            return live.chase_camera
        end
        return false
    end,
    GetInt  = function(_, key)
        if key == blackboard_defs.PlayerStateMachine.SceneTier then return live.scene_tier end
        if key == blackboard_defs.PlayerStateMachine.UpperBody then return live.upper_body end
        error("unexpected PlayerStateMachine field: " .. tostring(key))
    end,
}

Game = {
    GetPlayer = function()
        if not live.has_player then return nil end
        return { GetEntityID = function() return 1 end }
    end,
    GetBlackboardSystem = function()
        return {
            Get = function(_, _) return ui_blackboard end,
            GetLocalInstanced = function(_, _, _) return psm_blackboard end,
        }
    end,
}

local GameUI = require("modules/GameUI")
local State = require("modules/state")

local st

-- CET fires onInit once; that is what installs the game observers.
cet_events.onInit()


-- The gate caches its verdict for STATE_CACHE_TTL_S and only treats a latch as
-- stale once live state has contradicted it for STALE_LATCH_GRACE_S. Both
-- windows expiring on their own is the mechanism under test, so the test burns
-- real time rather than shortcutting with invalidateCache().
local function spin(seconds)
    local start = os.clock()
    while os.clock() - start < seconds do end
end

local function spinPastCacheTtl() spin(0.15) end

--- Evaluate the gate (arming the disagreement timer), let the grace window
--- elapse, evaluate again. The leading spin clears any still-fresh cached
--- verdict so the arming call actually re-probes, which in game happens for
--- free because the gate is evaluated every frame.
local function settleStaleLatch()
    spinPastCacheTtl()
    st:isTrackingAllowed()
    spin(1.1)
    return st:isTrackingAllowed()
end

st = State.new()
st:init(nil, nil)

print("== state gate ==")

-- 1. Plain gameplay.
assert_true(st:isTrackingAllowed(), "baseline gameplay allows tracking")

-- 2. The observer edge lands before the blackboard flips. The latch must
--    block on that frame and must NOT be discarded as stale, or every menu
--    would leak tracking the instant it opened.
observers["PauseMenuGameController.OnInitialize"]()
assert_false(st:isTrackingAllowed(), "fresh menu latch blocks before the blackboard flips")
assert_true(GameUI.IsMenuOpen(), "fresh menu latch is not cleared on a one-sample disagreement")

-- 3. Blackboard catches up; both sources now agree.
live.in_menu = true
spinPastCacheTtl()
assert_false(st:isTrackingAllowed(), "open menu blocks tracking")
assert_eq(st:getReason(), State.REASON.MENU, "block reason is menu")

-- 4. The close edge never arrives (the controller was re-created under us) but
--    the player is back in gameplay. This is the bug: pre-fix the latch pinned
--    the gate shut for the rest of the session.
live.in_menu = false
assert_true(settleStaleLatch(), "stale menu latch heals from live state")
assert_false(GameUI.IsMenuOpen(), "stale menu latch itself was cleared")

-- 5. Live menu state blocks even with no observer edge at all.
live.in_menu = true
spinPastCacheTtl()
assert_false(st:isTrackingAllowed(), "live IsInMenu blocks without an edge")
assert_eq(st:getReason(), State.REASON.MENU, "live block reason is menu")
live.in_menu = false
spinPastCacheTtl()
assert_true(st:isTrackingAllowed(), "leaving the menu resumes tracking")

-- 6. A real cinematic must NOT be cleared as stale: scene tier says the player
--    does not own the camera, so the latch is still telling the truth.
observers["SceneSystem.SetSceneSystemEnterConditionOverwritten"](nil, true)
live.scene_tier = 4
assert_false(settleStaleLatch(), "cinematic blocks tracking")
assert_eq(st:getReason(), State.REASON.SCENE, "block reason is scene")
assert_true(GameUI.IsScene(), "scene latch survives while tier says cinematic")

-- 7. Back to gameplay tier with the scene-end edge still missing.
live.scene_tier = 1
assert_true(settleStaleLatch(), "stale scene latch heals from live state")
assert_false(GameUI.IsScene(), "stale scene latch itself was cleared")

-- 8. No player (loading): the probe cannot answer, so the latches govern and
--    are left alone rather than guessed at.
live.has_player = false
observers["LoadingScreenProgressBarController.OnInitialize"]()
assert_false(settleStaleLatch(), "loading blocks tracking")
assert_eq(st:getReason(), State.REASON.LOADING, "block reason is loading")
assert_true(GameUI.IsLoading(), "loading latch survives while the probe cannot answer")

-- 9. Aiming down sights blocks tracking; lowering the weapon resumes it. The
--    game owns the sight picture while ADS is up, so head rotation stands down
--    for the duration.
live.has_player = true
settleStaleLatch()  -- clears the stale loading latch, which re-arms the warmup
spin(1.6)           -- WARMUP_SECONDS
assert_true(st:isTrackingAllowed(), "loading latch heals once the player is back")

live.upper_body = PSM_UPPERBODY_AIM
spinPastCacheTtl()
assert_false(st:isTrackingAllowed(), "ADS blocks tracking")
assert_eq(st:getReason(), State.REASON.ADS, "block reason is ads")

live.upper_body = 0
spinPastCacheTtl()
assert_true(st:isTrackingAllowed(), "leaving ADS resumes tracking")

-- 10. The ADS edge observers latch nothing, so an OnExit that never arrives
--     cannot strand tracking off - the next poll of the state machine is the
--     only thing that decides.
live.upper_body = PSM_UPPERBODY_AIM
observers["AimingStateEvents.OnEnter"]()
assert_false(st:isTrackingAllowed(), "ADS enter edge blocks on the same frame")
live.upper_body = 0
spinPastCacheTtl()
assert_true(st:isTrackingAllowed(), "ADS heals within the cache TTL with no OnExit edge")

-- 11. A real UI reason outranks ADS, so the status line names the menu rather
--     than the weapon the player happened to be holding.
live.in_menu = true
live.upper_body = PSM_UPPERBODY_AIM
spinPastCacheTtl()
assert_false(st:isTrackingAllowed(), "menu open blocks while ADS")
assert_eq(st:getReason(), State.REASON.MENU, "menu outranks ads")
live.in_menu = false
live.upper_body = 0
spinPastCacheTtl()
assert_true(st:isTrackingAllowed(), "back to gameplay")

-- 12. ads_mode decides whether ADS closes the gate at all. "paused" stands
--     tracking down; "marker" and "tracked" keep the gate open and hand the
--     decision to init.lua, which feeds poses relative to the one the sights
--     came up on. isAdsActive() is what tells init.lua the sights are up while
--     the gate is still open, so it has to be true for the whole aim.
local ads_mode = "paused"
st.settings = {
    get = function(_, key)
        if key == "ads_mode" then return ads_mode end
        return true  -- enabled / position_enabled
    end,
}

live.upper_body = PSM_UPPERBODY_AIM
spinPastCacheTtl()
assert_false(st:isTrackingAllowed(), "paused mode blocks on ADS")
assert_eq(st:getReason(), State.REASON.ADS, "paused mode reason is ads")
assert_true(st:isAdsActive(), "paused mode still reports ADS active")

ads_mode = "marker"
spinPastCacheTtl()
assert_true(st:isTrackingAllowed(), "marker mode keeps the gate open on ADS")
assert_eq(st:getReason(), State.REASON.ALLOWED, "marker mode reason is allowed")
assert_true(st:isAdsActive(), "marker mode reports ADS active")

ads_mode = "tracked"
spinPastCacheTtl()
assert_true(st:isTrackingAllowed(), "tracked mode keeps the gate open on ADS")
assert_eq(st:getReason(), State.REASON.ALLOWED, "tracked mode reason is allowed")
assert_true(st:isAdsActive(), "tracked mode reports ADS active")

live.upper_body = 0
spinPastCacheTtl()
assert_true(st:isTrackingAllowed(), "lowering the weapon stays allowed")
assert_false(st:isAdsActive(), "lowering the weapon clears the ADS flag")

-- A menu returning early must not leave a stale ADS flag behind: init.lua
-- would otherwise hold a frozen pose through a suppression that already
-- peeled it.
ads_mode = "tracked"
live.upper_body = PSM_UPPERBODY_AIM
spinPastCacheTtl()
assert_true(st:isAdsActive(), "ADS flag set before the menu opens")
live.in_menu = true
spinPastCacheTtl()
assert_false(st:isTrackingAllowed(), "menu blocks while ADS in tracked mode")
assert_false(st:isAdsActive(), "menu clears the ADS flag")
live.in_menu = false
live.upper_body = 0

-- The chase-camera flag decides WHERE the head rotation goes, so it has to be
-- false whenever tracking is suppressed as well: init.lua reads it to hand the
-- pose to the native render-side injection, and a stale true would keep that
-- injecting through a menu.
live.chase_camera = true
spinPastCacheTtl()
assert_true(st:isTrackingAllowed(), "driving in third person does not block tracking")
assert_true(st:isChaseCameraActive(), "chase camera reported while driving in third person")

live.in_menu = true
spinPastCacheTtl()
assert_false(st:isTrackingAllowed(), "menu blocks while in the chase camera")
assert_false(st:isChaseCameraActive(), "menu clears the chase-camera flag")

live.in_menu = false
live.chase_camera = false
spinPastCacheTtl()
assert_true(st:isTrackingAllowed(), "back to gameplay after the menu")
assert_false(st:isChaseCameraActive(), "first-person driving is not the chase camera")

print("== State gate OK ==")
