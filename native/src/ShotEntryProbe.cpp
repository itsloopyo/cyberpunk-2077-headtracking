// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
// ShotEntryProbe: diagnostic hook on +0x4E4AFC, the projectile/hitscan
// dispatcher called from the player-shot caller +0x79ACA0 in a loop over
// shot entries (one entry per shot/pellet).
//
// Ghidra decompile of FUN_1404e4afc establishes:
//   param_2 (rdx) = shot entry. First 0x10 bytes are consumed as a vec4
//     and transformed through conj(shooterState+0x80) - the candidate
//     head-contaminated aim value for automatic follow-up shots.
//   param_3 (r8)  = shooter state. +0x80..0x8C is a quaternion (xyz are
//     sign-flipped before use = conjugate). +0x1E20/24/28 and +0x70/74/78
//     are fixed-point vec3 positions (scale 1/131072).
//
// This probe only LOGS. It answers, per shot of a sustained burst:
//   1. Does +0x4E4AFC fire once per follow-up shot? (counter vs shots)
//   2. Which field rotates with head pose while the mouse is still?
//   3. Is the player discriminable by return RVA / LMB state?

#include "ShotEntryProbe.hpp"

#include <Windows.h>
#include <atomic>
#include <cmath>
#include <cstdint>

#include "NativeRunningHook.hpp"
#include "QuatMath.hpp"
#include "SharedState.hpp"

extern SharedState g_sharedState;

void LogInfo(const char* fmt, ...);
void LogError(const char* fmt, ...);

namespace {

constexpr uintptr_t kShotDispatchOffset = 0x4E4AFC;
constexpr float kFixedScale = 7.6293945e-06f;

// Peel mode: at dispatcher entry, multiply the shooter state's pellet-slot
// quats (+0x80 + k*0x3A0, k=0..3) and the source transform quat (+0x1E30)
// by inv(head). The slots consumed by this frame's per-pellet shot
// computation were written LAST frame (slot refresh happens at the bottom
// of the dispatcher / in the +0x79ACA0 tail loop), so an entry-peel lands
// before consumption. No restore: the engine rewrites the slots every
// frame, and the renderer never reads them.
constexpr bool kPeelSlots = false;  // proven no-op (shooterState+0x80 not the ray)
constexpr int  kPelletSlots = 4;
constexpr uint32_t kSlotStride = 0x3A0;
constexpr uint32_t kSlotQuatOffset = 0x80;
constexpr uint32_t kSourceQuatOffset = 0x1E30;

// THE aim decouple (verified 2026-06-10 by anchor-overlap A/B): the shooter
// state's aim quaternion at +0x1E30 is what the bullet ray derives from, and
// it is refreshed from the (head-rotated) camera every frame BEFORE this
// dispatcher runs. Peeling it at entry - aim_clean = aim * conj(head) - makes
// every shot (incl. automatic follow-ups) fly along the mouse-clean direction
// while the renderer keeps the head-rotated view. The conj sign was settled
// empirically: 'mul' (q*head) doubles the error, 'inv' (q*conj(head)) lands
// the peeled burst exactly on the pose-0 anchor cluster.
//
// BRACKETED: peel at entry, restore the original at exit. The engine's
// camera-follow path reads this same aim state OUTSIDE the dispatcher call;
// leaving the slot clean de-tracks the view from the head and double-peels
// the next frame (bullets mirror the reticle) - both observed live
// 2026-06-10 with the unrestored variant. No LMB gate: bullets only consume
// the quat inside this call, so an unconditional bracket covers taps and
// first shots without click-edge timing.
//
// 2026-06-10 LATER: even bracketed, the view DE-TRACKS - the engine's
// camera-follow consumer of this aim state runs INSIDE the +0x4E4AFC call
// window, same as the bullet consumer. The peel must bracket only the
// bullet-consuming CHILD function. Disabled pending the child-level hook.
constexpr bool kPeelAimQuat = false;
constexpr bool kLogEntries  = false;  // probe logging off in shipping builds

// Trace-dispatch cam bracket: +0x1303EC (FUN_1401303ec) is the per-pellet
// physics trace dispatcher (~52 calls per 1.5s SMG burst, ~0 idle). The
// per-pellet trace direction is expressed in CAMERA-LOCAL space; head
// rotation enters via the camera-to-world transform read from cam+0xD0 at
// trace time. Bracketing cam+0xD0 = clean for the synchronous duration of
// the trace makes EVERY pellet (incl. automatic follow-ups) fly along the
// mouse-clean direction, while the render thread keeps reading the
// head-rotated cam between traces. Gated on LMB so the per-frame body-yaw
// subsystem never samples the clean cam outside a shot.
constexpr uintptr_t kTraceDispatchOffset = 0x1303EC;
// Proven 2026-06-10: bracketing cam+0xD0 clean around +0x1303EC does NOT
// move bullets. The per-pellet ray is baked head-rotated UPSTREAM of this
// trace (arg3 direction is pose-invariant here = camera-local input, but the
// world ray it consumes was already computed elsewhere). Left disabled.
constexpr bool kBracketTrace = false;

using ShotDispatchFn = void (*)(void* rcx, void* rdx, void* r8, void* r9);

using TraceDispatchFn = uintptr_t (*)(void* a1, void* a2, void* a3, void* a4, void* a5, void* a6);

void*            s_target   = nullptr;
ShotDispatchFn   s_original = nullptr;
std::atomic<bool> s_hooked{false};
uintptr_t        s_exeBase  = 0;

void*            s_traceTarget   = nullptr;
TraceDispatchFn  s_traceOriginal = nullptr;
std::atomic<bool> s_traceHooked{false};
std::atomic<uint32_t> s_traceCalls{0};
std::atomic<uint32_t> s_traceBracketed{0};

std::atomic<uint32_t> s_calls{0};
std::atomic<uint32_t> s_logged{0};
std::atomic<uint32_t> s_lmbCalls{0};
std::atomic<uint32_t> s_peeled{0};
std::atomic<uint32_t> s_peelSkipped{0};
uint64_t              s_lastHeartbeatMs = 0;

constexpr uint32_t kMaxLoggedCalls = 400;

struct EntrySnapshot {
    float    entryF[8];
    uint32_t entryH[8];
    float    stateQuat[4];
    float    fixed70[3];
    float    fixed1E20[3];
    uint32_t ctxCounter;
    bool     ok;
};

EntrySnapshot ReadSnapshot(void* ctx, void* entry, void* state) {
    EntrySnapshot s{};
    __try {
        const float*    ef = reinterpret_cast<const float*>(entry);
        const uint32_t* eh = reinterpret_cast<const uint32_t*>(entry);
        for (int i = 0; i < 8; ++i) {
            s.entryF[i] = ef[i];
            s.entryH[i] = eh[i];
        }
        const uint8_t* st = reinterpret_cast<const uint8_t*>(state);
        const float* q = reinterpret_cast<const float*>(st + 0x80);
        for (int i = 0; i < 4; ++i) s.stateQuat[i] = q[i];
        const int32_t* f70 = reinterpret_cast<const int32_t*>(st + 0x70);
        const int32_t* f1e20 = reinterpret_cast<const int32_t*>(st + 0x1E20);
        for (int i = 0; i < 3; ++i) {
            s.fixed70[i]   = static_cast<float>(f70[i]) * kFixedScale;
            s.fixed1E20[i] = static_cast<float>(f1e20[i]) * kFixedScale;
        }
        s.ctxCounter = ctx ? *reinterpret_cast<const uint32_t*>(ctx) : 0xffffffffu;
        s.ok = true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s.ok = false;
    }
    return s;
}

using quatmath::QuatMul;

// Multiply the quat at `slot` by inv(head) in place. Returns false when the
// slot does not hold a unit-ish quat (left untouched).
bool PeelQuatInPlace(float* slot, float ihx, float ihy, float ihz, float ihw) {
    const float cx = slot[0], cy = slot[1], cz = slot[2], cw = slot[3];
    const float lenSq = cx*cx + cy*cy + cz*cz + cw*cw;
    if (!std::isfinite(lenSq) || lenSq < 0.5f || lenSq > 1.5f) return false;
    float nx, ny, nz, nw;
    QuatMul(cx, cy, cz, cw, ihx, ihy, ihz, ihw, nx, ny, nz, nw);
    const float nLenSq = nx*nx + ny*ny + nz*nz + nw*nw;
    if (!std::isfinite(nLenSq) || nLenSq < 0.01f) return false;
    const float invLen = 1.0f / std::sqrt(nLenSq);
    slot[0] = nx * invLen;
    slot[1] = ny * invLen;
    slot[2] = nz * invLen;
    slot[3] = nw * invLen;
    return true;
}

// Peel the aim quat at +0x1E30 in place: q' = q * conj(head), saving the
// original into `saved`. Returns the slot pointer when peeled, nullptr when
// skipped (invalid quat) or faulted. The caller MUST restore `saved` into the
// returned slot after the original function returns: the engine's
// camera-follow path reads this same aim state later in the frame, and
// leaving it clean de-tracks the view (and turns the next frame's refresh
// into a double-peel - bullets mirror the reticle). Both observed 2026-06-10.
float* PeelAimQuatBracket(void* state, float hx, float hy, float hz, float hw,
                          float saved[4]) {
    __try {
        float* q = reinterpret_cast<float*>(
            reinterpret_cast<uint8_t*>(state) + kSourceQuatOffset);
        const float cx = q[0], cy = q[1], cz = q[2], cw = q[3];
        const float lenSq = cx*cx + cy*cy + cz*cz + cw*cw;
        if (!std::isfinite(lenSq) || lenSq < 0.9f || lenSq > 1.1f) return nullptr;
        float nx, ny, nz, nw;
        QuatMul(cx, cy, cz, cw, -hx, -hy, -hz, hw, nx, ny, nz, nw);
        const float nLenSq = nx*nx + ny*ny + nz*nz + nw*nw;
        if (!std::isfinite(nLenSq) || nLenSq < 0.01f) return nullptr;
        saved[0] = cx; saved[1] = cy; saved[2] = cz; saved[3] = cw;
        const float invLen = 1.0f / std::sqrt(nLenSq);
        q[0] = nx * invLen;
        q[1] = ny * invLen;
        q[2] = nz * invLen;
        q[3] = nw * invLen;
        return q;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return nullptr;
    }
}

void RestoreAimQuat(float* slot, const float saved[4]) {
    __try {
        slot[0] = saved[0];
        slot[1] = saved[1];
        slot[2] = saved[2];
        slot[3] = saved[3];
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_peelSkipped.fetch_add(1, std::memory_order_relaxed);
    }
}

// Peel all pellet-slot quats + the source quat on one shooter state.
// Returns the number of quats peeled, or -1 on fault.
int PeelShooterState(void* state, float ihx, float ihy, float ihz, float ihw) {
    int peeled = 0;
    __try {
        uint8_t* st = reinterpret_cast<uint8_t*>(state);
        for (int k = 0; k < kPelletSlots; ++k) {
            float* q = reinterpret_cast<float*>(st + kSlotQuatOffset + k * kSlotStride);
            if (PeelQuatInPlace(q, ihx, ihy, ihz, ihw)) ++peeled;
        }
        float* src = reinterpret_cast<float*>(st + kSourceQuatOffset);
        if (PeelQuatInPlace(src, ihx, ihy, ihz, ihw)) ++peeled;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return -1;
    }
    return peeled;
}

void Hook_ShotDispatch(void* rcx, void* rdx, void* r8, void* r9) {
    const uint32_t call = s_calls.fetch_add(1, std::memory_order_relaxed) + 1;
    const uintptr_t retAddr = reinterpret_cast<uintptr_t>(_ReturnAddress());
    const uintptr_t retRva = (s_exeBase != 0 && retAddr >= s_exeBase) ? (retAddr - s_exeBase) : 0;
    const bool lmbDown = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;
    if (lmbDown) s_lmbCalls.fetch_add(1, std::memory_order_relaxed);

    const bool wantLog =
        kLogEntries &&
        (call <= 8 || lmbDown) &&
        s_logged.load(std::memory_order_relaxed) < kMaxLoggedCalls;

    if (wantLog) {
        s_logged.fetch_add(1, std::memory_order_relaxed);
        EntrySnapshot s = ReadSnapshot(rcx, rdx, r8);
        HeadTrackingState ht{};
        if (g_sharedState.IsAvailable()) ht = g_sharedState.Read();
        if (s.ok) {
            LogInfo("[ShotEntry] #%u ret=+0x%llX lmb=%d ctr=%u yaw=%.2f pitch=%.2f head=(%+.4f,%+.4f,%+.4f,%+.4f)",
                    call, (unsigned long long)retRva, lmbDown ? 1 : 0, s.ctxCounter,
                    ht.yaw, ht.pitch,
                    g_headQuat[0], g_headQuat[1], g_headQuat[2], g_headQuat[3]);
            LogInfo("[ShotEntry] #%u entryF=(%+.4f,%+.4f,%+.4f,%+.4f | %+.4f,%+.4f,%+.4f,%+.4f) entryH=(%08X %08X %08X %08X | %08X %08X %08X %08X)",
                    call,
                    s.entryF[0], s.entryF[1], s.entryF[2], s.entryF[3],
                    s.entryF[4], s.entryF[5], s.entryF[6], s.entryF[7],
                    s.entryH[0], s.entryH[1], s.entryH[2], s.entryH[3],
                    s.entryH[4], s.entryH[5], s.entryH[6], s.entryH[7]);
            LogInfo("[ShotEntry] #%u stateQuat+0x80=(%+.4f,%+.4f,%+.4f,%+.4f) fix70=(%.3f,%.3f,%.3f) fix1E20=(%.3f,%.3f,%.3f)",
                    call,
                    s.stateQuat[0], s.stateQuat[1], s.stateQuat[2], s.stateQuat[3],
                    s.fixed70[0], s.fixed70[1], s.fixed70[2],
                    s.fixed1E20[0], s.fixed1E20[1], s.fixed1E20[2]);
        } else {
            LogInfo("[ShotEntry] #%u ret=+0x%llX lmb=%d snapshot FAULT (rcx=%p rdx=%p r8=%p)",
                    call, (unsigned long long)retRva, lmbDown ? 1 : 0, rcx, rdx, r8);
        }
    }

    float peelSaved[4] = {0, 0, 0, 1};
    float* peelSlot = nullptr;
    if (kPeelAimQuat) {
        const float hx = g_headQuat[0];
        const float hy = g_headQuat[1];
        const float hz = g_headQuat[2];
        const float hw = g_headQuat[3];
        const float hLenSq = hx*hx + hy*hy + hz*hz + hw*hw;
        const float headDelta =
            std::fabs(hx) + std::fabs(hy) + std::fabs(hz) +
            std::fabs(1.0f - std::fabs(hw));
        if (std::isfinite(hLenSq) && hLenSq > 0.5f && hLenSq < 1.5f &&
            headDelta >= 0.002f) {
            peelSlot = PeelAimQuatBracket(r8, hx, hy, hz, hw, peelSaved);
            if (peelSlot) {
                const uint32_t c = s_peeled.fetch_add(1, std::memory_order_relaxed) + 1;
                if (c <= 4 || (c % 4096) == 0) {
                    LogInfo("[AimPeel] #%u state=%p head=(%+.4f,%+.4f,%+.4f,%+.4f)",
                            c, r8, hx, hy, hz, hw);
                }
            }
        }
    }

    if (kPeelSlots && lmbDown) {
        const float hx = g_headQuat[0];
        const float hy = g_headQuat[1];
        const float hz = g_headQuat[2];
        const float hw = g_headQuat[3];
        const float hLenSq = hx*hx + hy*hy + hz*hz + hw*hw;
        const float headDelta =
            std::fabs(hx) + std::fabs(hy) + std::fabs(hz) +
            std::fabs(1.0f - std::fabs(hw));
        if (std::isfinite(hLenSq) && hLenSq > 0.5f && hLenSq < 1.5f &&
            headDelta >= 0.005f) {
            const int n = PeelShooterState(r8, -hx, -hy, -hz, hw);
            if (n > 0) {
                const uint32_t c = s_peeled.fetch_add(1, std::memory_order_relaxed) + 1;
                if (c <= 8 || (c % 128) == 0) {
                    LogInfo("[ShotEntry] peel #%u quats=%d state=%p head=(%+.4f,%+.4f,%+.4f,%+.4f)",
                            c, n, r8, hx, hy, hz, hw);
                }
            } else {
                s_peelSkipped.fetch_add(1, std::memory_order_relaxed);
            }
        } else {
            s_peelSkipped.fetch_add(1, std::memory_order_relaxed);
        }
    }

    if (s_original) {
        s_original(rcx, rdx, r8, r9);
    }

    if (peelSlot) {
        RestoreAimQuat(peelSlot, peelSaved);
    }

    const uint64_t now = GetTickCount64();
    if (s_lastHeartbeatMs == 0 || now - s_lastHeartbeatMs > 5000) {
        s_lastHeartbeatMs = now;
        LogInfo("[ShotEntry] heartbeat: calls=%u lmb_calls=%u logged=%u peeled=%u peel_skipped=%u",
                s_calls.load(std::memory_order_relaxed),
                s_lmbCalls.load(std::memory_order_relaxed),
                s_logged.load(std::memory_order_relaxed),
                s_peeled.load(std::memory_order_relaxed),
                s_peelSkipped.load(std::memory_order_relaxed));
    }
}

uintptr_t Hook_TraceDispatch(void* a1, void* a2, void* a3, void* a4, void* a5, void* a6) {
    s_traceCalls.fetch_add(1, std::memory_order_relaxed);

    bool bracketed = false;
    float saved[4] = {0, 0, 0, 1};
    float* slot = nullptr;

    if (kBracketTrace && (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0) {
        void* cam = g_camInstance;
        const int camOff = g_camOrientationOffset;
        const float hx = g_headQuat[0];
        const float hy = g_headQuat[1];
        const float hz = g_headQuat[2];
        const float hw = g_headQuat[3];
        const float hLenSq = hx*hx + hy*hy + hz*hz + hw*hw;
        const float headDelta =
            std::fabs(hx) + std::fabs(hy) + std::fabs(hz) +
            std::fabs(1.0f - std::fabs(hw));
        if (cam && camOff >= 0 && std::isfinite(hLenSq) &&
            hLenSq > 0.5f && hLenSq < 1.5f && headDelta >= 0.005f) {
            __try {
                slot = reinterpret_cast<float*>(
                    reinterpret_cast<uint8_t*>(cam) + camOff);
                const float cx = slot[0], cy = slot[1], cz = slot[2], cw = slot[3];
                const float cLenSq = cx*cx + cy*cy + cz*cz + cw*cw;
                if (std::isfinite(cLenSq) && cLenSq > 0.5f && cLenSq < 1.5f) {
                    saved[0] = cx; saved[1] = cy; saved[2] = cz; saved[3] = cw;
                    float nx, ny, nz, nw;
                    QuatMul(cx, cy, cz, cw, -hx, -hy, -hz, hw, nx, ny, nz, nw);
                    const float nLenSq = nx*nx + ny*ny + nz*nz + nw*nw;
                    if (std::isfinite(nLenSq) && nLenSq > 0.01f) {
                        const float invLen = 1.0f / std::sqrt(nLenSq);
                        slot[0] = nx * invLen;
                        slot[1] = ny * invLen;
                        slot[2] = nz * invLen;
                        slot[3] = nw * invLen;
                        bracketed = true;
                        const uint32_t c = s_traceBracketed.fetch_add(1, std::memory_order_relaxed) + 1;
                        if (c <= 6 || (c % 256) == 0) {
                            LogInfo("[TraceBracket] #%u saved=(%+.4f,%+.4f,%+.4f,%+.4f) -> clean=(%+.4f,%+.4f,%+.4f,%+.4f)",
                                    c, saved[0], saved[1], saved[2], saved[3],
                                    slot[0], slot[1], slot[2], slot[3]);
                        }
                    }
                } else {
                    slot = nullptr;
                }
            } __except (EXCEPTION_EXECUTE_HANDLER) {
                slot = nullptr;
                bracketed = false;
            }
        }
    }

    uintptr_t result = 0;
    if (s_traceOriginal) {
        result = s_traceOriginal(a1, a2, a3, a4, a5, a6);
    }

    if (bracketed && slot) {
        __try {
            slot[0] = saved[0];
            slot[1] = saved[1];
            slot[2] = saved[2];
            slot[3] = saved[3];
        } __except (EXCEPTION_EXECUTE_HANDLER) {
        }
    }
    return result;
}

}  // namespace

bool ShotEntryProbe_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (s_hooked.load(std::memory_order_acquire)) return true;
    if (!sdk) return false;

    HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
    if (!hModule) {
        LogError("[ShotEntry] Cyberpunk2077.exe handle not found");
        return false;
    }
    s_exeBase = reinterpret_cast<uintptr_t>(hModule);
    s_target = reinterpret_cast<void*>(s_exeBase + kShotDispatchOffset);

    const bool attached = sdk->hooking->Attach(handle,
                                               s_target,
                                               reinterpret_cast<void*>(&Hook_ShotDispatch),
                                               reinterpret_cast<void**>(&s_original));
    if (!attached) {
        LogError("[ShotEntry] Attach failed at +0x%llX",
                 (unsigned long long)kShotDispatchOffset);
        s_target = nullptr;
        s_original = nullptr;
        return false;
    }

    s_hooked.store(true, std::memory_order_release);
    LogInfo("[ShotEntry] probe installed at +0x%llX", (unsigned long long)kShotDispatchOffset);

    if (kBracketTrace) {
        s_traceTarget = reinterpret_cast<void*>(s_exeBase + kTraceDispatchOffset);
        const bool tattached = sdk->hooking->Attach(handle,
                                                    s_traceTarget,
                                                    reinterpret_cast<void*>(&Hook_TraceDispatch),
                                                    reinterpret_cast<void**>(&s_traceOriginal));
        if (tattached) {
            s_traceHooked.store(true, std::memory_order_release);
            LogInfo("[TraceBracket] hook installed at +0x%llX", (unsigned long long)kTraceDispatchOffset);
        } else {
            LogError("[TraceBracket] Attach failed at +0x%llX", (unsigned long long)kTraceDispatchOffset);
            s_traceTarget = nullptr;
            s_traceOriginal = nullptr;
        }
    }
    return true;
}

void ShotEntryProbe_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (s_traceHooked.exchange(false, std::memory_order_acq_rel)) {
        if (sdk && s_traceTarget) sdk->hooking->Detach(handle, s_traceTarget);
        s_traceTarget = nullptr;
        s_traceOriginal = nullptr;
    }
    if (!s_hooked.exchange(false, std::memory_order_acq_rel)) return;
    if (sdk && s_target) {
        sdk->hooking->Detach(handle, s_target);
    }
    s_target = nullptr;
    s_original = nullptr;
    LogInfo("[ShotEntry] probe detached");
}

bool ShotEntryProbe_IsActive() {
    return s_hooked.load(std::memory_order_acquire);
}
