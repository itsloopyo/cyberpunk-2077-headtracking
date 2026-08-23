// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "NativeRunningHook.hpp"
#include "SharedState.hpp"
#include "AimCompensation.hpp"  // LogInfo / LogWarning
#include "AimProviderHook.hpp"
#include "AimGetterHook.hpp"
#include "ScriptChannel.hpp"

#include <RED4ext/RED4ext.hpp>
#include <RED4ext/GameStates.hpp>
#include <RED4ext/Api/v1/GameState.hpp>
#include <RED4ext/Api/v1/GameStates.hpp>
#include <RED4ext/Api/v1/Sdk.hpp>

// Phase 2b extras: RTTI walk to call entICameraComponent::SetLocalOrientation
// from native on the FPP camera of the local player. Headers here must be
// header-only (RED4EXT_HEADER_ONLY is defined in CMake) so the -inl.hpp
// definitions are pulled in.
#include <RED4ext/GameEngine.hpp>
#include <RED4ext/RTTISystem.hpp>
#include <RED4ext/Handle.hpp>
#include <RED4ext/Scripting/Functions.hpp>
#include <RED4ext/Scripting/Stack.hpp>
#include <RED4ext/Scripting/Natives/ScriptGameInstance.hpp>
#include <RED4ext/Scripting/Natives/Quaternion.hpp>

#include <windows.h>

// NativeRunningHook.hpp now declares g_camInstance and
// g_camOrientationOffset as extern; their single definitions live
// at the bottom of this file.

namespace {

// Static storage for the callback struct. RED4ext docs say "can be
// allocated on stack" but the pointer must stay valid for as long as
// the callback is registered; safer to keep it in BSS.
RED4ext::v1::GameState s_state{};

uint64_t s_lastLogMs = 0;
uint32_t s_prevLogCount = 0;
// Last reported values of the fields worth a line. `head=` and the frame
// counter move every frame, so they are carried by the line but never gate it.
void*    s_loggedCam = nullptr;
int      s_loggedCamOff = -1;
int      s_loggedGate = -1;
int      s_loggedAds = -1;
bool     s_loggedAlive = false;
uint64_t s_lastLiveLogMs = 0;
bool     s_enterFired = false;
uint64_t s_firstRunningMs = 0;
uint64_t s_lastNoScriptWarnMs = 0;

bool OnEnter(RED4ext::CGameApplication*) {
    s_enterFired = true;
    if (s_firstRunningMs == 0) s_firstRunningMs = GetTickCount64();
    LogInfo("[HeadTrackingAim] NativeRunningHook: OnEnter Running");
    return true;
}

// -----------------------------------------------------------------------------
// Phase 2b: CRTTI walk to call entICameraComponent::SetLocalOrientation
// -----------------------------------------------------------------------------
//
// When true, ConsumePendingRestore actually invokes SetLocalOrientation
// on the local player's FPP camera using the saved quat. When false
// (dry-run), only the resolution pointers are logged so we can verify
// the walk finds valid function/class handles before letting it write
// anything. The safe default is dry-run: on first encounter with a
// pending flag, we log the chain state, ack, and leave the Lua-side
// Aim:tickSnapRestore as the actual restore mechanism.
//
// Flip to true, rebuild, redeploy. If it misbehaves (game crashes, cam
// stuck mid-rotation, etc.) flip back - the Lua fallback picks up.
//
// Phase 2b finding (2026-04-21): the CRTTI walk works and SetLocalOrientation
// does land on the correct cam, but Running::OnUpdate fires at a tick phase
// that does NOT sit between hitscan and render. Running OnUpdate is kept as
// a secondary path (logs and diagnostics). The primary native restore now
// directly - that lands the cam write in the post-hitscan / pre-render
// window of the SAME frame, which is what actually kills the render flash.

// Cached RTTI call chain. Lazily resolved on first ConsumePendingRestore
// hit with a pending flag. Invalidated (set back to null) if any step of
// a call fails, so a transient null during load screens self-heals.
struct CamCallChain {
    RED4ext::CBaseRTTIType* scriptGameInstanceType = nullptr;
    RED4ext::CBaseRTTIType* quaternionType = nullptr;
    RED4ext::CBaseRTTIType* playerPuppetRefType = nullptr;
    RED4ext::CBaseRTTIType* fppCamRefType = nullptr;
    RED4ext::CBaseFunction* getPlayerFn = nullptr;      // global: GetPlayer(GameInstance)
    RED4ext::CBaseFunction* getFPPCamFn = nullptr;      // PlayerPuppet: GetFPPCameraComponent()
    RED4ext::CBaseFunction* setLocalOrientationFn = nullptr; // entICameraComponent: SetLocalOrientation(Quaternion)
    bool logged_once = false;
};
static CamCallChain s_chain;

// Resolve as many parts of the call chain as possible. Returns how many
// of the 7 slots were found; caller decides whether to proceed.
// Never throws - every lookup is via a stable RED4ext pointer.
static int ResolveCallChain() {
    int resolved = 0;
    auto rtti = RED4ext::CRTTISystem::Get();
    if (!rtti) return 0;

    if (!s_chain.scriptGameInstanceType) {
        s_chain.scriptGameInstanceType = rtti->GetType(RED4ext::CName("ScriptGameInstance"));
    }
    if (s_chain.scriptGameInstanceType) ++resolved;

    if (!s_chain.quaternionType) {
        s_chain.quaternionType = rtti->GetType(RED4ext::CName("Quaternion"));
    }
    if (s_chain.quaternionType) ++resolved;

    if (!s_chain.playerPuppetRefType) {
        // The return type of GetPlayer is Ref<PlayerPuppet> - in RTTI that's
        // the name "handle:PlayerPuppet". If exact name varies between patches
        // we fall through to a generic handle type.
        s_chain.playerPuppetRefType = rtti->GetType(RED4ext::CName("handle:PlayerPuppet"));
    }
    if (s_chain.playerPuppetRefType) ++resolved;

    if (!s_chain.fppCamRefType) {
        s_chain.fppCamRefType = rtti->GetType(RED4ext::CName("handle:gameFPPCameraComponent"));
        if (!s_chain.fppCamRefType) {
            // Modern Cyberpunk versions use entICameraComponent for the handle.
            s_chain.fppCamRefType = rtti->GetType(RED4ext::CName("handle:entICameraComponent"));
        }
    }
    if (s_chain.fppCamRefType) ++resolved;

    if (!s_chain.getPlayerFn) {
        // Global functions in RED4 RTTI are indexed by their full signature
        // ("short;arg1;arg2"), not just short name. Try the canonical form
        // first, then fall back to the short name for older patches.
        static const char* kGetPlayerCandidates[] = {
            "GetPlayer;GameInstance",
            "GetPlayer",
        };
        for (auto name : kGetPlayerCandidates) {
            s_chain.getPlayerFn = rtti->GetFunction(RED4ext::CName(name));
            if (s_chain.getPlayerFn) break;
        }
    }
    if (s_chain.getPlayerFn) ++resolved;

    if (!s_chain.getFPPCamFn) {
        auto playerCls = rtti->GetClass(RED4ext::CName("PlayerPuppet"));
        if (playerCls) {
            s_chain.getFPPCamFn = playerCls->GetFunction(RED4ext::CName("GetFPPCameraComponent"));
        }
    }
    if (s_chain.getFPPCamFn) ++resolved;

    if (!s_chain.setLocalOrientationFn) {
        // SetLocalOrientation is defined on entIPlacedComponent (parent
        // of all cameras) in current CP2077. Older comments wrongly
        // placed it on entICameraComponent. Walk a set of candidates so
        // an engine refactor doesn't silently break us.
        static const char* kCamClassCandidates[] = {
            "entIPlacedComponent",
            "entICameraComponent",
            "gameCameraComponent",
            "gameFPPCameraComponent",
        };
        for (auto cls_name : kCamClassCandidates) {
            auto cls = rtti->GetClass(RED4ext::CName(cls_name));
            if (!cls) continue;
            auto fn = cls->GetFunction(RED4ext::CName("SetLocalOrientation"));
            if (fn) {
                s_chain.setLocalOrientationFn = fn;
                break;
            }
        }
    }
    if (s_chain.setLocalOrientationFn) ++resolved;

    if (!s_chain.logged_once && resolved > 0) {
        LogInfo("[HeadTrackingAim] Phase 2b CRTTI walk: resolved=%d/7 "
                "{sgi=%p quat=%p pp_ref=%p cam_ref=%p GetPlayer=%p GetFPPCam=%p SetLocalOri=%p}",
                resolved,
                (void*)s_chain.scriptGameInstanceType,
                (void*)s_chain.quaternionType,
                (void*)s_chain.playerPuppetRefType,
                (void*)s_chain.fppCamRefType,
                (void*)s_chain.getPlayerFn,
                (void*)s_chain.getFPPCamFn,
                (void*)s_chain.setLocalOrientationFn);
        if (resolved == 7) {
            s_chain.logged_once = true;
            LogInfo("[HeadTrackingAim] CRTTI walk: full resolution");
        }
    }

    return resolved;
}

// SEH-only helper: call fn->Execute(stack) under __try/__except. Lives in
// a separate function because MSVC (C2712) forbids __try in a function
// whose stack frame contains C++ objects with destructors. This helper
// takes only pointers, so no unwinding is required. All the real objects
// (ScriptGameInstance, Handle, CStack, Quaternion) stay in the caller.
// Returns true on normal return, false on access violation or similar.
static bool SehExecute(RED4ext::CBaseFunction* fn, RED4ext::CStack* stack) {
    if (!fn || !stack) return false;
    __try {
        fn->Execute(stack);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
    return true;
}

// Walk the CRTTI chain to get a raw IScriptable* for the local player's
// FPP camera. Returns null on any intermediate failure. Shares the
// from safe contexts (NativeRunningHook's OnUpdate); NOT from the render
// pipeline hook where scripted dispatch has caused crashes.
static RED4ext::IScriptable* ResolveCamInstance() {
    if (ResolveCallChain() != 7) return nullptr;
    auto engine = RED4ext::CGameEngine::Get();
    if (!engine || !engine->framework || !engine->framework->gameInstance) return nullptr;

    RED4ext::ScriptGameInstance sgi(engine->framework->gameInstance);
    RED4ext::Handle<RED4ext::IScriptable> playerHandle{};
    {
        RED4ext::CStackType args[1];
        args[0].type = s_chain.scriptGameInstanceType;
        args[0].value = &sgi;
        RED4ext::CStackType result;
        result.type = s_chain.playerPuppetRefType;
        result.value = &playerHandle;
        RED4ext::CStack stack(nullptr, args, 1, &result);
        if (!SehExecute(s_chain.getPlayerFn, &stack)) return nullptr;
    }
    if (!playerHandle.instance) return nullptr;

    RED4ext::Handle<RED4ext::IScriptable> camHandle{};
    {
        RED4ext::CStackType result;
        result.type = s_chain.fppCamRefType;
        result.value = &camHandle;
        RED4ext::CStack stack(playerHandle.instance, nullptr, 0, &result);
        if (!SehExecute(s_chain.getFPPCamFn, &stack)) return nullptr;
    }
    return camHandle.instance;
}

// SEH-wrapped float read from a possibly-bad pointer. Returns 0.0f on
// fault so the scan can continue past invalid regions. (The scan range
// is 2 KB; a page fault at an invalid boundary shouldn't happen given
// heap alignment but we defend anyway.)
static bool SehReadFloat(const void* addr, float* out) {
    __try {
        *out = *reinterpret_cast<const float*>(addr);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        *out = 0.0f;
        return false;
    }
}

// Scan the first 2 KB of `cam` memory for 4 consecutive floats matching
// (qi,qj,qk,qr) within tolerance EPS. Returns the byte offset if found,
// or -1. Offsets 0..7 (vtable) are skipped. Steps by 4 bytes - localOrientation
// is a Quaternion, aligned to at least 4 bytes in MSVC layout.
//
// This is a ONE-SHOT discovery: once we find the offset we cache it and
// never scan again. The offset is a compile-time struct layout so
// re-scanning is wasteful. The hardcoded offset (once known) lets the
// render-path hook do a direct 16-byte memcpy with no scripted dispatch,
// which is the only safe way to touch cam orientation from the render
// pipeline.
static int ScanOrientationOffset(void* cam, float qi, float qj, float qk, float qr) {
    if (!cam) return -1;
    const uint8_t* base = reinterpret_cast<const uint8_t*>(cam);
    constexpr int kScanEnd   = 0x800;   // 2 KB
    constexpr int kScanStart = 8;       // past vtable
    constexpr float kEps     = 1e-4f;
    for (int off = kScanStart; off + 16 <= kScanEnd; off += 4) {
        float f0, f1, f2, f3;
        if (!SehReadFloat(base + off + 0,  &f0)) continue;
        if (!SehReadFloat(base + off + 4,  &f1)) continue;
        if (!SehReadFloat(base + off + 8,  &f2)) continue;
        if (!SehReadFloat(base + off + 12, &f3)) continue;
        if (std::fabs(f0 - qi) < kEps &&
            std::fabs(f1 - qj) < kEps &&
            std::fabs(f2 - qk) < kEps &&
            std::fabs(f3 - qr) < kEps) {
            return off;
        }
    }
    return -1;
}

// Byte offset of the Quaternion orientation field within the FPP cam
// instance. Confirmed stable at +0xD0 across multiple game sessions
// (2026-04-22). Hardcoded rather than scanned because:
//       (head-rotated) but also immediately writes clean_quat into the
//       cam's orientation field, so by the time native scans the cam
//       memory contains `clean`, not `saved` - the scan misses;
//   (b) it's a compile-time struct layout, stable across game runs
//       within the same patch version. If a future patch moves it the
//       ScanOrientationOffset() helper (still present) can re-find it.
static constexpr int kFPPCamOrientationOffset = 0xD0;
static int s_camOrientationOffset = kFPPCamOrientationOffset;  // pre-seeded baseline
// Cached cam instance pointer. Null until first successful ResolveCamInstance.
static RED4ext::IScriptable* s_camInstance = nullptr;

bool OnUpdate(RED4ext::CGameApplication*) {
    // Provider vtables can only be patched once the RTTI registry is up, which
    // is long after plugin load - this retries until it takes, then just mirrors
    // counters.
    AimProviderHook_Tick();
    AimGetterHook_Tick();

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->native_running_frame++;

        // Mirror the current head quat into the lock-free global so the
        // pre-render hook can rotate outMatrix's cached forward vectors
        // without ever touching SHM (SHM access
        // from inside the render trampoline has crashed the game).
        //
        // `enabled` gates the mirror, not just the consumers. While tracking
        // is suppressed - menus, cinematics, aiming down sights - Lua peels
        // its rotation back out of the camera and stops publishing fresh
        // quats, so the last one it wrote describes a rotation that is no
        // longer in the view. AimProviderHook and AimGetterHook decide whether
        // to peel from the quat alone, so mirroring a stale one has them peel
        // a rotation nothing applied and throws the player's shots off by
        // whatever head angle they were holding when tracking stood down.
        // Identity here is what "nothing to peel" looks like to both.
        if (w->enabled) {
            g_headQuat[0] = w->quat_i;
            g_headQuat[1] = w->quat_j;
            g_headQuat[2] = w->quat_k;
            g_headQuat[3] = w->quat_r;
        } else {
            g_headQuat[0] = 0.0f;
            g_headQuat[1] = 0.0f;
            g_headQuat[2] = 0.0f;
            g_headQuat[3] = 1.0f;
        }

        // Resolve the cam instance pointer periodically even without a
        // Needed so `g_camInstance` is populated as
        // soon as the player is in gameplay - otherwise the Frida
        // watchpoint tools can't find the cam pointer until the user
        // has fired at least once, which defeats the point of watching
        // the first hitscan read.
        //
        // ResolveCamInstance walks the CRTTI chain every time; it's
        // cheap but not free, so rate-limit to once per ~30 ticks
        // (~250ms at 120Hz).
        {
            static uint32_t s_resolveCounter = 0;
            if (::g_camInstance == nullptr || (++s_resolveCounter % 30) == 0) {
                if (auto* cam = ResolveCamInstance()) {
                    ::g_camInstance = cam;
                }
            }
        }

        // Click ring-dump REMOVED 2026-05-08. The pre-render hook
        // target was disproven as a camera function (~33k fires/s,
        // 275/frame, every camStatePtr unique within 100ms = it's a
        // per-renderable-entity transform builder, not per-camera).
        // All ring data was noise. See DECOUPLING.md.
        //
        // Heartbeat on a 30s wall clock, and only when the diagnostic picture
        // actually changed: at 3s unconditional this was ~1200 lines an hour of
        // a line whose interesting half (cam pointer, offset, CET gate, ADS)
        // does not move once gameplay settles, which buried the startup chain a
        // user is asked to read. A 5-minute liveness line keeps a quiet log
        // proving the per-frame callback is still firing.
        const uint64_t now = GetTickCount64();
        if (s_lastLogMs == 0) {
            s_lastLogMs = now;
            s_prevLogCount = w->native_running_frame;
        } else if ((now - s_lastLogMs) > 30000) {
            const uint64_t elapsedMs = now - s_lastLogMs;
            const uint32_t delta = w->native_running_frame - s_prevLogCount;
            const double hz = (elapsedMs > 0) ? (delta * 1000.0 / elapsedMs) : 0.0;
            const int gateState = !ScriptChannel_HasEverPushed() ? 0
                                  : (ScriptChannel_LastPushEnabled() ? 1 : 2);
            const char* gate = gateState == 0 ? "none" : (gateState == 1 ? "open" : "SHUT");
            const int ads = ScriptChannel_LastPushIsAds() ? 1 : 0;
            const bool alive = delta > 0;
            const bool changed = ::g_camInstance != s_loggedCam ||
                                 ::g_camOrientationOffset != s_loggedCamOff ||
                                 gateState != s_loggedGate ||
                                 ads != s_loggedAds ||
                                 alive != s_loggedAlive;
            if (changed || (now - s_lastLiveLogMs) > 300000) {
                LogInfo("[HeadTrackingAim] NativeRunningHook heartbeat: frame=%u (+%u in %llums = %.1f Hz) "
                        "cam=%p cam_ori_off=+0x%X cet_gate=%s ads=%d head=%.1fdeg",
                        w->native_running_frame, delta,
                        (unsigned long long)elapsedMs, hz,
                        (void*)::g_camInstance,
                        ::g_camOrientationOffset,
                        gate, ads,
                        ScriptChannel_LastPushHeadDegrees());
                s_lastLiveLogMs = now;
                s_loggedCam = ::g_camInstance;
                s_loggedCamOff = ::g_camOrientationOffset;
                s_loggedGate = gateState;
                s_loggedAds = ads;
                s_loggedAlive = alive;
            }
            s_lastLogMs = now;
            s_prevLogCount = w->native_running_frame;

            // Everything above can look perfectly healthy while the mod does
            // nothing at all: the plugin loads, UDP arrives, the hooks fire,
            // and the pose stays at identity because the CET half never came
            // up. That failure shipped once already and cost a user a session
            // and a bug report to diagnose, so name it in the log people
            // actually send us.
            if (!ScriptChannel_HasEverPushed()) {
                if (now - s_firstRunningMs > 15000 && now - s_lastNoScriptWarnMs > 30000) {
                    s_lastNoScriptWarnMs = now;
                    LogWarning("[HeadTrackingAim] no state from the CET mod after %llus in gameplay - "
                               "head tracking will do nothing. Check that the HeadTracking CET mod is "
                               "installed under bin/x64/plugins/cyber_engine_tweaks/mods/HeadTracking "
                               "and read scripting.log for its init errors.",
                               (unsigned long long)((now - s_firstRunningMs) / 1000));
                }
            } else if (ScriptChannel_MsSinceLastPush() > 5000 && now - s_lastNoScriptWarnMs > 30000) {
                s_lastNoScriptWarnMs = now;
                LogWarning("[HeadTrackingAim] CET mod stopped pushing state %llums ago - "
                           "tracking is frozen at its last pose.",
                           (unsigned long long)ScriptChannel_MsSinceLastPush());
            }
        }
    }
    // RED4ext treats `true` from OnUpdate as "state done, stop calling".
    // Docs say return value is ignored for Running, but empirically the
    // callback stopped firing after returning true, so we return false
    // to guarantee continuous per-frame invocation.
    return false;
}

bool OnExit(RED4ext::CGameApplication*) {
    LogInfo("[HeadTrackingAim] NativeRunningHook: OnExit Running");
    return true;
}

} // namespace

// File-scope globals mirrored from the anonymous-namespace statics
// above. Kept in lockstep whenever the statics are updated. Exposed so
// the render-path hook in CameraHook.cpp can read them DIRECTLY with no
// cross-TU function call (even a tiny cross-TU call crashes the game
// when invoked from inside that hook).
//
// g_camOrientationOffset: initialized to the known-stable +0xD0 baseline
// so the render hook can start doing DirectWrites as soon as g_camInstance
// is populated - doesn't need to wait for a (now-always-skipped) scan.
RED4ext::IScriptable* g_camInstance = nullptr;
int                    g_camOrientationOffset = 0xD0;

bool NativeRunningHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (!sdk || !sdk->gameStates) {
        LogWarning("[HeadTrackingAim] NativeRunningHook: sdk->gameStates not available");
        return false;
    }
    s_state.OnEnter  = &OnEnter;
    s_state.OnUpdate = &OnUpdate;
    s_state.OnExit   = &OnExit;

    const bool added = sdk->gameStates->Add(handle, RED4ext::EGameStateType::Running, &s_state);
    if (added) {
        LogInfo("[HeadTrackingAim] NativeRunningHook: registered for Running state");
    } else {
        LogWarning("[HeadTrackingAim] NativeRunningHook: gameStates->Add returned false");
    }
    return added;
}

void NativeRunningHook_Stop(const RED4ext::v1::Sdk*, RED4ext::v1::PluginHandle) {
    // RED4ext has no GameState::Remove. The callback struct is static, so
    // if the plugin is unloaded the pointer becomes invalid - but RED4ext
    // only invokes GameState callbacks while the plugin is loaded, so
    // this is effectively self-cleaning. No-op.
}

// SEH-wrapped 4-float write. Lives in a separate function because the
// caller (Hook_PreRender in CameraHook) has C++ objects with destructors
// in scope which C2712 forbids pairing with __try.
static bool SehWriteQuat(void* dst, float qi, float qj, float qk, float qr) {
    __try {
        float* p = reinterpret_cast<float*>(dst);
        p[0] = qi;
        p[1] = qj;
        p[2] = qk;
        p[3] = qr;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// --- SHM-free pre-render staging -------------------------------------
// The pre-render hook fires 10k+ times per second and has crashed the
// game whenever we try to access the shared-memory mapping directly from
// it (even a single non-branching read). Instead, NativeRunningHook
// (OnUpdate context, proven safe for SHM) mirrors the pending state
// into these thread-safe atomics, and the pre-render hook only ever
// reads those. The quat is stored in plain floats protected by the
// atomic seq counter: writers stage the quat first, then flip the
// atomic to signal readiness; readers check the atomic and copy out
// the quat only if set.

// Continuously-mirrored head quat. OnUpdate writes it from SHM every
// tick; the render hook reads plain floats (no atomic needed - single
// writer, single reader, and the pre-render hook is allowed to see a
// one-tick stale value without consequence).
float                 g_headQuat[4] = {0, 0, 0, 1};
