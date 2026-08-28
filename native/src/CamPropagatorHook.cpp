// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "CamPropagatorHook.hpp"

#include <Windows.h>
#include <atomic>
#include <cmath>
#include <cstdint>

#include "ModuleGuard.hpp"
#include "NativeRunningHook.hpp"
#include "QuatMath.hpp"
#include "SharedState.hpp"
#include "builds/build_registry.hpp"

extern SharedState g_sharedState;

void LogInfo(const char* fmt, ...);
void LogError(const char* fmt, ...);

namespace {

using PropagatorFn = void (*)(void* self, bool markDirty);

void* s_target = nullptr;
PropagatorFn s_original = nullptr;
std::atomic<bool> s_hooked{false};
std::atomic<uint32_t> s_calls{0};
std::atomic<uint32_t> s_injected{0};
std::atomic<uint32_t> s_skipped{0};
// The hook runs on several game threads at once, so the log gate has to be
// claimed atomically. A plain timestamp updated after LogInfo lets every
// thread pass the same check while the first one is still inside the file
// write, and the identical line comes out once per thread.
uint64_t s_lastLogMs = 0;
bool     s_haveLogged = false;
uint32_t s_loggedInjected = 0;
void*    s_loggedCam = nullptr;
int      s_loggedOff = 0;
uint32_t s_flushedCalls = 0;
thread_local uint32_t t_depth = 0;

// The injection gate, mirrored out of shared memory once per frame by
// CamPropagatorHook_Tick. Reading it per call meant copying 208 bytes out of
// the mapping and sanity-checking 30-odd floats to answer a question that only
// changes at frame cadence, on a function the game calls up to half a million
// times a second across several threads. Same pattern as g_headQuat in
// NativeRunningHook.
std::atomic<bool> s_gateOpen{false};

inline bool IsValidUnitish(float x, float y, float z, float w) {
    const float lenSq = x*x + y*y + z*z + w*w;
    return std::isfinite(lenSq) && lenSq > 0.5f && lenSq < 1.5f;
}

using quatmath::QuatMul;

void Hook_Propagator(void* self, bool markDirty) {
    s_calls.fetch_add(1, std::memory_order_relaxed);

    bool wrote = false;
    float saved[4] = {0, 0, 0, 1};
    float* slot = nullptr;

    if (t_depth == 0) {
        const bool gateOpen = s_gateOpen.load(std::memory_order_relaxed);

        void* cam = g_camInstance;
        const int camOff = g_camOrientationOffset;
        const float hx = g_headQuat[0];
        const float hy = g_headQuat[1];
        const float hz = g_headQuat[2];
        const float hw = g_headQuat[3];

        if (gateOpen && cam && camOff >= 0 && IsValidUnitish(hx, hy, hz, hw)) {
            __try {
                slot = reinterpret_cast<float*>(reinterpret_cast<uint8_t*>(cam) + camOff);
                const float cx = slot[0];
                const float cy = slot[1];
                const float cz = slot[2];
                const float cw = slot[3];
                if (IsValidUnitish(cx, cy, cz, cw)) {
                    saved[0] = cx;
                    saved[1] = cy;
                    saved[2] = cz;
                    saved[3] = cw;

                    float nx, ny, nz, nw;
                    QuatMul(cx, cy, cz, cw, hx, hy, hz, hw, nx, ny, nz, nw);
                    const float lenSq = nx*nx + ny*ny + nz*nz + nw*nw;
                    if (std::isfinite(lenSq) && lenSq > 0.01f) {
                        const float invLen = 1.0f / std::sqrt(lenSq);
                        slot[0] = nx * invLen;
                        slot[1] = ny * invLen;
                        slot[2] = nz * invLen;
                        slot[3] = nw * invLen;
                        wrote = true;
                        s_injected.fetch_add(1, std::memory_order_relaxed);
                    }
                }
            } __except (EXCEPTION_EXECUTE_HANDLER) {
                wrote = false;
                slot = nullptr;
            }
        } else {
            s_skipped.fetch_add(1, std::memory_order_relaxed);
        }
    }

    ++t_depth;
    if (s_original) {
        s_original(self, markDirty);
    }
    --t_depth;

    if (wrote && slot) {
        __try {
            slot[0] = saved[0];
            slot[1] = saved[1];
            slot[2] = saved[2];
            slot[3] = saved[3];
        } __except (EXCEPTION_EXECUTE_HANDLER) {
        }
    }
}

}  // namespace

void CamPropagatorHook_Tick(bool gateOpen) {
    s_gateOpen.store(gateOpen, std::memory_order_relaxed);

    const uint32_t calls = s_calls.load(std::memory_order_relaxed);
    if (calls == s_flushedCalls) return;   // hook not firing; nothing to report

    // camera_hook_fires and propagator_hook_fires are heartbeat counters read
    // from outside the process, so they have to keep advancing without losing
    // counts. They do not need per-call freshness, and writing them from every
    // thread that entered the hook had one shared cache line bouncing between
    // cores at the hook's full call rate.
    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        const uint32_t delta = calls - s_flushedCalls;
        w->camera_hook_active = true;
        w->camera_hook_fires += delta;
        w->propagator_hook_fires += delta;
    }
    s_flushedCalls = calls;

    // `calls` and `skipped` climb on every invocation, so a plain 3s heartbeat
    // repeats a line that says nothing: propagator injection is off in the
    // shipped config, which pins `injected` at 0 and leaves the cam pointer and
    // offset stable for the whole session. That was 30% of the log. Report a
    // change the moment it happens, and otherwise keep a 5-minute liveness line
    // so a quiet log still proves the hook is firing.
    const uint64_t now = GetTickCount64();
    const uint32_t injected = s_injected.load(std::memory_order_relaxed);
    const bool first = !s_haveLogged;
    const bool changed = first ||
                         injected != s_loggedInjected ||
                         g_camInstance != s_loggedCam ||
                         g_camOrientationOffset != s_loggedOff;
    const uint64_t sinceLog = now - s_lastLogMs;
    if (first || (changed && sinceLog >= 3000) || sinceLog >= 300000) {
        s_lastLogMs = now;
        s_haveLogged = true;
        s_loggedInjected = injected;
        s_loggedCam = g_camInstance;
        s_loggedOff = g_camOrientationOffset;
        LogInfo("[CamPropagator] heartbeat: calls=%u injected=%u skipped=%u cam=%p off=%d",
                calls,
                injected,
                s_skipped.load(std::memory_order_relaxed),
                g_camInstance,
                g_camOrientationOffset);
    }
}

bool CamPropagatorHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (s_hooked.load(std::memory_order_acquire)) return true;
    if (!sdk) return false;

    // A detour written at an RVA that no longer belongs to this build lands in
    // whatever occupies the address instead, which crashes the game seconds in.
    // The fingerprint gate is what rules that out; ResolveCodeRva below is only
    // a bounds check and cannot tell a moved function from a matching one.
    if (!builds::HasActiveProfile()) {
        LogInfo("[CamPropagator] no matching build profile - hook not installed");
        return false;
    }
    const uintptr_t rva = builds::ActiveProfile().Offsets.Propagator;
    if (rva == 0) {
        LogInfo("[CamPropagator] profile %s carries no propagator RVA - hook not installed",
                builds::ActiveProfile().Name);
        return false;
    }

    const uintptr_t target = modguard::ResolveCodeRva(rva, 16, "CamPropagator");
    if (!target) return false;

    s_target = reinterpret_cast<void*>(target);
    const bool attached = sdk->hooking->Attach(handle,
                                               s_target,
                                               reinterpret_cast<void*>(&Hook_Propagator),
                                               reinterpret_cast<void**>(&s_original));
    if (!attached) {
        LogError("[CamPropagator] attach failed at +0x%llX",
                 static_cast<unsigned long long>(rva));
        s_target = nullptr;
        s_original = nullptr;
        return false;
    }

    s_hooked.store(true, std::memory_order_release);
    LogInfo("[CamPropagator] hook installed at +0x%llX",
            static_cast<unsigned long long>(rva));
    return true;
}

void CamPropagatorHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (!s_hooked.exchange(false, std::memory_order_acq_rel)) return;
    if (sdk && s_target) {
        sdk->hooking->Detach(handle, s_target);
    }
    s_target = nullptr;
    s_original = nullptr;
    LogInfo("[CamPropagator] hook detached");
}

bool CamPropagatorHook_IsActive() {
    return s_hooked.load(std::memory_order_acquire);
}
