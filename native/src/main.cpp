// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include <RED4ext/RED4ext.hpp>
#include <windows.h>
#include "SharedState.hpp"
#include "AimCompensation.hpp"
#include "UdpReceiver.hpp"
#include "ScriptChannel.hpp"
#include "NativeRunningHook.hpp"
#include "CamPropagatorHook.hpp"
#include "AimProviderHook.hpp"
#include "PositionProviderHook.hpp"
#include "AimGetterHook.hpp"
#include "builds/build_registry.hpp"

// Standard OpenTrack UDP port. If you change this, also change the OpenTrack
// Output configuration (IP: 127.0.0.1, Port: 4242).
constexpr uint16_t kUdpPort = 4242;


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

        // Queue the script channel before anything else can need it. This only
        // asks the RTTI system to call us back when it builds its registry, so
        // it cannot fail here and has nothing to undo on an early return.
        ScriptChannel_Register();

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

        // Fingerprint the running EXE before a single detour goes in. On a
        // build we do not recognise the RVA-pinned hooks below stay dormant
        // and log why; the tracking pipeline, the camera and the projectile
        // aim decoupling resolve their targets by name and carry on.
        builds::SelectProfile();

        NativeRunningHook_Start(aSdk, aHandle);
        CamPropagatorHook_Start(aSdk, aHandle);

        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->camera_hook_active = CamPropagatorHook_IsActive();
            w->camera_hook_fires  = 0;
            w->propagator_inject_active = 0;
            w->propagator_hook_fires    = 0;
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

        break;

    case RED4ext::v1::EMainReason::Unload:
        // Unregister the per-frame Running callback FIRST. AimProviderHook
        // installs itself from OnUpdate and re-installs whenever it sees
        // itself uninstalled, so tearing hooks down while OnUpdate is still
        // firing left the game running our thunks out of a DLL that is on its
        // way out of the address space.
        NativeRunningHook_Stop(aSdk, aHandle);

        AimGetterHook_Stop(aSdk, aHandle);
        PositionProviderHook_Stop();
        AimProviderHook_Stop();
        UdpReceiver_Stop();

        CamPropagatorHook_Stop(aSdk, aHandle);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->camera_hook_active = false;
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
