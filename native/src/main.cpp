// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include <RED4ext/RED4ext.hpp>
#include <windows.h>
#include "SharedState.hpp"
#include "AimCompensation.hpp"
#include "UdpReceiver.hpp"
#include "TcpServer.hpp"
#include "NativeRunningHook.hpp"
#include "CamPropagatorHook.hpp"
#include "HitscanHook.hpp"
#include "ShotSnapHook.hpp"
#include "ShotEntryProbe.hpp"
#include "FreezeFrameHook.hpp"
#include "AimProviderHook.hpp"
#include "AimGetterHook.hpp"

// Standard OpenTrack UDP port. If you change this, also change the OpenTrack
// Output configuration (IP: 127.0.0.1, Port: 4242).
constexpr uint16_t kUdpPort = 4242;

// TCP port the CET Lua mod connects to via RedSocket. Shares the number with
// kUdpPort - TCP and UDP live in separate port namespaces, so 4242/tcp and
// 4242/udp can both be bound on the same host without conflict. Hardcoded
// here and in modules/udp.lua; keep them in sync.
constexpr uint16_t kTcpPort = 4242;

RED4EXT_C_EXPORT bool RED4EXT_CALL Main(RED4ext::v1::PluginHandle aHandle,
                                         RED4ext::v1::EMainReason aReason,
                                         const RED4ext::v1::Sdk* aSdk) {
    switch (aReason) {
    case RED4ext::v1::EMainReason::Load:
        if (!g_sharedState.Init()) {
            LogError("[HeadTrackingAim] Failed to initialize shared memory");
            return false;
        }
        LogInfo("[HeadTrackingAim] Shared memory initialized");

        // Start the UDP receiver BEFORE attaching hooks so that even if a
        // hook target is stale and the plugin refuses to load, we've already
        // told the user WHY via logs (UDP binding issues surface here, hook
        // issues surface below). A returned-false here is a catastrophic
        // init failure (e.g. WSAStartup); port-in-use is NOT fatal - the
        // receiver schedules a background retry loop and the rest of the
        // plugin keeps loading so tracking comes online the moment the
        // conflicting holder releases the port.
        if (!UdpReceiver_Start(kUdpPort)) {
            LogError("[HeadTrackingAim] UDP receiver failed to initialise on port %u - refusing to load", kUdpPort);
            g_sharedState.Shutdown();
            return false;
        }

        // CET Lua mod reads tracking data via RedSocket (TCP) - some CET
        // versions don't expose ffi, so shared memory is unreachable from Lua.
        if (!TcpServer_Start(kTcpPort)) {
            LogError("[HeadTrackingAim] TCP server failed to start on port %u - refusing to load", kTcpPort);
            UdpReceiver_Stop();
            g_sharedState.Shutdown();
            return false;
        }

        NativeRunningHook_Start(aSdk, aHandle);
        CamPropagatorHook_Start(aSdk, aHandle);
        HitscanHook_Start(aSdk, aHandle);
        // Decoupling status (2026-06-10): the shooter-state aim quat at
        // +0x1E30 is the bullet's aim source (peeling it redirects bullets),
        // but the engine round-trips it back to the camera every frame inside
        // +0x4E4AFC, so cleaning it also de-tracks the view. Confirmed across
        // the quat, the +0x80 pellet slots, the +0x4E4030 stack copy, and a
        // full child-by-child hole sweep - every shooter-state mutation
        // de-tracks the view. cam+0xD0 snapping (ShotSnapHook) does NOT reach
        // the bullet at all. So both native experiments stay disabled and the
        // ship behaviour is the Lua SNAP-CLEAN (single-shot decouple). The
        // ShotEntryProbe carries the disabled AimPeel for the next attempt:
        // peel the trace's camera transform (param_1+0x48 at +0x1303EC), the
        // only +0x1E30 consumer downstream of the camera writeback.
        // ShotEntryProbe_Start(aSdk, aHandle);

        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->camera_hook_active = CamPropagatorHook_IsActive();
            w->camera_hook_fires  = 0;
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires  = 0;
            w->propagator_inject_active = 0;
            w->propagator_hook_fires    = 0;
            w->freeze_frame_enabled     = 1;
            w->provider_hook_active     = 0;
            w->provider_mode            = 1;  // camera-match gated peel
            w->provider_calls           = 0;
            w->provider_overrides       = 0;
            // Instrument only until a lever is confirmed to move bullets:
            // the hooks count calls and log the head/local/world pose, and
            // mutate nothing. tools/set_aim_mode.py flips the mode live.
            w->aim_getter_mode          = 1;
            w->aim_getter_calls_a       = 0;
            w->aim_getter_calls_b       = 0;
            w->aim_getter_calls_c       = 0;
            w->aim_getter_overrides     = 0;
        }

        AimGetterHook_Start(aSdk, aHandle);

        FreezeFrameHook_Start();
        break;

    case RED4ext::v1::EMainReason::Unload:
        // Unregister the per-frame Running callback FIRST. AimProviderHook
        // installs itself from OnUpdate and re-installs whenever it sees
        // itself uninstalled, so tearing hooks down while OnUpdate is still
        // firing left the game running our thunks out of a DLL that is on its
        // way out of the address space.
        NativeRunningHook_Stop(aSdk, aHandle);

        AimGetterHook_Stop(aSdk, aHandle);
        AimProviderHook_Stop();
        FreezeFrameHook_Stop();
        TcpServer_Stop();
        UdpReceiver_Stop();

        ShotEntryProbe_Stop(aSdk, aHandle);
        ShotSnapHook_Stop(aSdk, aHandle);  // no-op if never started
        HitscanHook_Stop(aSdk, aHandle);
        CamPropagatorHook_Stop(aSdk, aHandle);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->camera_hook_active = false;
            w->hitscan_hook_active = false;
        }

        g_sharedState.Shutdown();
        LogInfo("[HeadTrackingAim] Shared memory shutdown");
        break;
    }

    return true;
}

RED4EXT_C_EXPORT void RED4EXT_CALL Query(RED4ext::v1::PluginInfo* aInfo) {
    aInfo->name = L"HeadTrackingAim";
    aInfo->author = L"HeadTracking";
    aInfo->version = RED4EXT_V1_SEMVER(0, 0, 0);
    aInfo->runtime = RED4EXT_V1_RUNTIME_VERSION_LATEST;
    // Report SDK 0.5.0 via the compat macro - RED4ext 1.29.x enforces an
    // exact SDK-version match against 0.5.0. v1 SDK is wire-compatible
    // with 0.5.0; this just makes the loader accept us.
    aInfo->sdk = RED4EXT_V1_SDK_VERSION_1_0_0_COMPAT_0_5_0;
}

RED4EXT_C_EXPORT uint32_t RED4EXT_CALL Supports() {
    // v0 and v1 are ABI-identical; reporting v0 via the compat macro keeps
    // us loadable by stable RED4ext loaders (1.29.x) that don't recognise
    // v1 yet. Newer loaders accept it too.
    return RED4EXT_API_VERSION_1_COMPAT_0;
}
