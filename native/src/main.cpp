#include <RED4ext/RED4ext.hpp>
#include <windows.h>
#include "SharedState.hpp"
#include "AimCompensation.hpp"
#include "UdpReceiver.hpp"
#include "TcpServer.hpp"
#include "NativeRunningHook.hpp"
#include "HitscanHook.hpp"
#include "ShotSnapHook.hpp"
#include "FreezeFrameHook.hpp"

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
        // receiver schedules a 5s retry loop and the rest of the plugin
        // keeps loading so tracking comes online the moment the conflicting
        // holder releases the port.
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
        HitscanHook_Start(aSdk, aHandle);
        // ShotSnapHook (native cam+0xD0 bracket) is intentionally NOT started:
        // proven 2026-05-28 to be a no-op for SMG/shotgun decoupling (the
        // auto-fire shot ray does not read cam.localOrientation). Files kept in
        // tree for the native shot-vector path. Re-enable only if that path
        // needs the camera bracket too.
        // ShotSnapHook_Start(aSdk, aHandle);

        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires  = 0;
            w->propagator_inject_active = 0;
            w->propagator_hook_fires    = 0;
            w->freeze_frame_enabled     = 1;
        }

        FreezeFrameHook_Start();
        break;

    case RED4ext::v1::EMainReason::Unload:
        FreezeFrameHook_Stop();
        TcpServer_Stop();
        UdpReceiver_Stop();

        ShotSnapHook_Stop(aSdk, aHandle);  // no-op if never started
        HitscanHook_Stop(aSdk, aHandle);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }

        NativeRunningHook_Stop(aSdk, aHandle);

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
