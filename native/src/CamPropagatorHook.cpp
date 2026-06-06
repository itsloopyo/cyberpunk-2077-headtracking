#include "CamPropagatorHook.hpp"

#include <Windows.h>
#include <atomic>
#include <cmath>
#include <cstdint>

#include "NativeRunningHook.hpp"
#include "SharedState.hpp"

extern SharedState g_sharedState;

void LogInfo(const char* fmt, ...);
void LogError(const char* fmt, ...);

namespace {

constexpr uintptr_t kPropagatorOffset = 0x1D8558;

using PropagatorFn = void (*)(void* self, bool markDirty);

void* s_target = nullptr;
PropagatorFn s_original = nullptr;
std::atomic<bool> s_hooked{false};
std::atomic<uint32_t> s_calls{0};
std::atomic<uint32_t> s_injected{0};
std::atomic<uint32_t> s_skipped{0};
uint64_t s_lastHeartbeatMs = 0;
thread_local uint32_t t_depth = 0;

inline bool IsValidUnitish(float x, float y, float z, float w) {
    const float lenSq = x*x + y*y + z*z + w*w;
    return std::isfinite(lenSq) && lenSq > 0.5f && lenSq < 1.5f;
}

inline void QuatMul(float ax, float ay, float az, float aw,
                    float bx, float by, float bz, float bw,
                    float& ox, float& oy, float& oz, float& ow) {
    ox = aw*bx + ax*bw + ay*bz - az*by;
    oy = aw*by - ax*bz + ay*bw + az*bx;
    oz = aw*bz + ax*by - ay*bx + az*bw;
    ow = aw*bw - ax*bx - ay*by - az*bz;
}

void Hook_Propagator(void* self, bool markDirty) {
    s_calls.fetch_add(1, std::memory_order_relaxed);

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->camera_hook_active = true;
        w->camera_hook_fires++;
        w->propagator_hook_fires++;
    }

    bool wrote = false;
    float saved[4] = {0, 0, 0, 1};
    float* slot = nullptr;

    if (t_depth == 0) {
        HeadTrackingState state{};
        if (g_sharedState.IsAvailable()) {
            state = g_sharedState.Read();
        }

        const bool gateOpen =
            state.enabled &&
            state.camera_hook_inject &&
            state.propagator_inject_active != 0u &&
            state.applied_frame > 0;

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

    const uint64_t now = GetTickCount64();
    if (s_lastHeartbeatMs == 0 || now - s_lastHeartbeatMs > 3000) {
        s_lastHeartbeatMs = now;
        LogInfo("[CamPropagator] heartbeat: calls=%u injected=%u skipped=%u cam=%p off=%d",
                s_calls.load(std::memory_order_relaxed),
                s_injected.load(std::memory_order_relaxed),
                s_skipped.load(std::memory_order_relaxed),
                g_camInstance,
                g_camOrientationOffset);
    }
}

}  // namespace

bool CamPropagatorHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (s_hooked.load(std::memory_order_acquire)) return true;
    if (!sdk) return false;

    HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
    if (!hModule) {
        LogError("[CamPropagator] Cyberpunk2077.exe handle not found");
        return false;
    }

    const uintptr_t base = reinterpret_cast<uintptr_t>(hModule);
    s_target = reinterpret_cast<void*>(base + kPropagatorOffset);
    const bool attached = sdk->hooking->Attach(handle,
                                               s_target,
                                               reinterpret_cast<void*>(&Hook_Propagator),
                                               reinterpret_cast<void**>(&s_original));
    if (!attached) {
        LogError("[CamPropagator] attach failed at +0x%llX",
                 static_cast<unsigned long long>(kPropagatorOffset));
        s_target = nullptr;
        s_original = nullptr;
        return false;
    }

    s_hooked.store(true, std::memory_order_release);
    LogInfo("[CamPropagator] hook installed at +0x%llX",
            static_cast<unsigned long long>(kPropagatorOffset));
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
