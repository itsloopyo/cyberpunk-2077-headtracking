// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
// ShotSnapHook: native-side snap-clean of the FPP cam orientation around
// the player shot computation.
//
// Architecture:
//   FUN_14079ACA0 (+0x79ACA0) is the player-shot caller that runs both
//   the visual/effect dispatcher (+0x46EE60) and the projectile/hitscan
//   dispatcher (+0x4E4AFC) synchronously on the game thread.
//
//   onEnter:
//     - Save FPP cam.localOrientation (cam+0xD0)
//     - Compose CLEAN = saved * inv(head_quat) so the cam reads as
//       mouse-only direction
//     - Write CLEAN into cam+0xD0
//   onLeave:
//     - Restore the head-rotated saved quat into cam+0xD0
//
//   Inside the function body, anything that reads cam.localOrientation to
//   determine the bullet ray (hitscan, raycast, projectile-spawn
//   orientation) sees CLEAN -> bullets fly along mouse direction. The
//   renderer reads cam.localOrientation on the render thread on its own
//   schedule; the snap window is the synchronous duration of the hooked
//   function (microseconds), so the rendered view keeps following the head.
//
// Gating (kSnapWhileHeld):
//   +0x79ACA0 fires ~17x per actual shot AND ~37Hz even between shots.
//   - true  (default): snap on EVERY call while LMB is held. This decouples
//     EVERY shot of automatic / burst weapons (SMG, auto shotgun) - not just
//     the first. The LMB-held gate keeps the snap from firing during the
//     between-shots idle calls so the body-yaw subsystem doesn't accumulate
//     the clean direction into V's facing.
//   - false: snap only on the LMB rising edge (one snap per click). Semi-auto
//     weapons (pistol) decouple every shot; automatic weapons decouple only
//     the first shot of a burst. This is the lower-drift fallback if
//     snap-while-held is found to walk V's body during sustained fire.

#include "ShotSnapHook.hpp"

#include <Windows.h>
#include <atomic>
#include <cmath>
#include <cstdint>

#include "NativeRunningHook.hpp"
#include "QuatMath.hpp"
#include "SharedState.hpp"

extern SharedState g_sharedState;

void LogInfo(const char* fmt, ...);
void LogWarning(const char* fmt, ...);
void LogError(const char* fmt, ...);

namespace {

constexpr uintptr_t kPlayerShotCallerOffset = 0x79ACA0;

constexpr bool kEnableSnap     = true;
// Snap on every call while LMB held (true) vs only on the LMB rising edge
// (false). True is required to decouple every shot of automatic weapons.
constexpr bool kSnapWhileHeld  = true;

using PlayerShotCallerFn = void (*)(void* rcx, void* rdx, void* r8, void* r9);

void*               s_target           = nullptr;
PlayerShotCallerFn  s_original         = nullptr;
std::atomic<bool>   s_hooked{false};

std::atomic<uint32_t> s_calls{0};
std::atomic<uint32_t> s_snapped{0};
std::atomic<uint32_t> s_skipped_no_cam{0};
std::atomic<uint32_t> s_skipped_identity{0};
std::atomic<uint32_t> s_restore_faults{0};
uint64_t              s_lastHeartbeatMs = 0;

using quatmath::QuatMul;

void Hook_PlayerShotCaller(void* rcx, void* rdx, void* r8, void* r9) {
    s_calls.fetch_add(1, std::memory_order_relaxed);

    bool snapped = false;
    float saved[4] = {0, 0, 0, 1};
    float* slot = nullptr;

    static std::atomic<bool> s_prevLmb{false};
    const bool lmbDown = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;
    const bool prevLmb = s_prevLmb.exchange(lmbDown, std::memory_order_acq_rel);
    const bool gateOpen = kSnapWhileHeld ? lmbDown : (lmbDown && !prevLmb);

    if (kEnableSnap && gateOpen) {
        void* cam = g_camInstance;
        const int camOff = g_camOrientationOffset;
        if (!cam || camOff < 0) {
            s_skipped_no_cam.fetch_add(1, std::memory_order_relaxed);
        } else {
            const float hx = g_headQuat[0];
            const float hy = g_headQuat[1];
            const float hz = g_headQuat[2];
            const float hw = g_headQuat[3];
            const float hLenSq = hx*hx + hy*hy + hz*hz + hw*hw;
            const float headDelta =
                std::fabs(hx) + std::fabs(hy) + std::fabs(hz) +
                std::fabs(1.0f - std::fabs(hw));
            if (!std::isfinite(hLenSq) || hLenSq < 0.5f || hLenSq > 1.5f ||
                headDelta < 0.005f) {
                s_skipped_identity.fetch_add(1, std::memory_order_relaxed);
            } else {
                __try {
                    slot = reinterpret_cast<float*>(
                        reinterpret_cast<uint8_t*>(cam) + camOff);
                    const float cx = slot[0], cy = slot[1], cz = slot[2], cw = slot[3];
                    const float cLenSq = cx*cx + cy*cy + cz*cz + cw*cw;
                    if (std::isfinite(cLenSq) && cLenSq > 0.5f && cLenSq < 1.5f) {
                        saved[0] = cx; saved[1] = cy; saved[2] = cz; saved[3] = cw;
                        // Lua composes: final_quat = clean_quat * head_quat
                        // (see modules/camera.lua). So cam+0xD0 reads as
                        //   saved = clean * head_quat (Lua sign convention).
                        // To peel: clean = saved * inv(head_quat).
                        // inv(head_quat) in Lua sign = (-hx, -hy, -hz, hw).
                        const float ihx = -hx, ihy = -hy, ihz = -hz, ihw = hw;
                        float nx, ny, nz, nw;
                        QuatMul(cx, cy, cz, cw, ihx, ihy, ihz, ihw,
                                nx, ny, nz, nw);
                        const float nLenSq = nx*nx + ny*ny + nz*nz + nw*nw;
                        if (std::isfinite(nLenSq) && nLenSq > 0.01f) {
                            const float invLen = 1.0f / std::sqrt(nLenSq);
                            slot[0] = nx * invLen;
                            slot[1] = ny * invLen;
                            slot[2] = nz * invLen;
                            slot[3] = nw * invLen;
                            snapped = true;
                            const uint32_t c = s_snapped.fetch_add(1, std::memory_order_relaxed) + 1;
                            if (c <= 8 || (c % 64) == 0) {
                                LogInfo("[ShotSnap] #%u head=(%+.4f,%+.4f,%+.4f,%+.4f) saved=(%+.4f,%+.4f,%+.4f,%+.4f) -> clean=(%+.4f,%+.4f,%+.4f,%+.4f)",
                                        c, hx, hy, hz, hw,
                                        cx, cy, cz, cw,
                                        slot[0], slot[1], slot[2], slot[3]);
                            }
                        }
                    } else {
                        slot = nullptr;
                    }
                } __except (EXCEPTION_EXECUTE_HANDLER) {
                    slot = nullptr;
                    snapped = false;
                }
            }
        }
    }

    if (s_original) {
        s_original(rcx, rdx, r8, r9);
    }

    if (snapped && slot) {
        __try {
            slot[0] = saved[0];
            slot[1] = saved[1];
            slot[2] = saved[2];
            slot[3] = saved[3];
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            s_restore_faults.fetch_add(1, std::memory_order_relaxed);
        }
    }

    const uint64_t now = GetTickCount64();
    if (s_lastHeartbeatMs == 0 || now - s_lastHeartbeatMs > 5000) {
        s_lastHeartbeatMs = now;
        LogInfo("[ShotSnap] heartbeat: calls=%u snapped=%u skipped_no_cam=%u skipped_identity=%u restore_faults=%u while_held=%d",
                s_calls.load(std::memory_order_relaxed),
                s_snapped.load(std::memory_order_relaxed),
                s_skipped_no_cam.load(std::memory_order_relaxed),
                s_skipped_identity.load(std::memory_order_relaxed),
                s_restore_faults.load(std::memory_order_relaxed),
                kSnapWhileHeld ? 1 : 0);
    }
}

}  // namespace

bool ShotSnapHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (s_hooked.load(std::memory_order_acquire)) return true;
    if (!sdk) return false;

    HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
    if (!hModule) {
        LogError("[ShotSnap] Cyberpunk2077.exe handle not found");
        return false;
    }
    const uintptr_t base = reinterpret_cast<uintptr_t>(hModule);
    s_target = reinterpret_cast<void*>(base + kPlayerShotCallerOffset);

    const bool attached = sdk->hooking->Attach(handle,
                                               s_target,
                                               reinterpret_cast<void*>(&Hook_PlayerShotCaller),
                                               reinterpret_cast<void**>(&s_original));
    if (!attached) {
        LogError("[ShotSnap] Attach failed at +0x%llX",
                 (unsigned long long)kPlayerShotCallerOffset);
        s_target = nullptr;
        s_original = nullptr;
        return false;
    }

    s_hooked.store(true, std::memory_order_release);
    LogInfo("[ShotSnap] hook installed at +0x%llX (while_held=%d)",
            (unsigned long long)kPlayerShotCallerOffset, kSnapWhileHeld ? 1 : 0);
    return true;
}

void ShotSnapHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (!s_hooked.exchange(false, std::memory_order_acq_rel)) return;
    if (sdk && s_target) {
        sdk->hooking->Detach(handle, s_target);
    }
    s_target = nullptr;
    s_original = nullptr;
    LogInfo("[ShotSnap] hook detached");
}

bool ShotSnapHook_IsActive() {
    return s_hooked.load(std::memory_order_acquire);
}
