// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
// AimProviderHook - decouple the bullet from the head by rewriting the aim
// orientation the shot ASKS for, instead of the camera state it reads.
//
// Background. Every previous decoupling attempt mutated shared camera state
// (cam+0xD0, the shooter-state aim quat at +0x1E30, the trace ray) and hit the
// same wall: the engine round-trips those values back into the camera, so a
// clean bullet always came with a de-tracked view, and the single-shot
// SNAP-CLEAN workaround could not cover automatic fire.
//
// The projectile launch does not read the camera directly. It asks an
// entIOrientationProvider (gameprojectileLaunchParams.logicalOrientationProvider,
// built by gameAttack_Projectile::PrepareAttack) for the launch orientation, and
// for the player that provider returns the camera orientation. The provider
// writes its answer into a CALLER-OWNED temporary. Rewriting that temporary:
//   - never touches camera state, so nothing round-trips and the view keeps
//     following the head,
//   - happens once per pellet per round, so automatic weapons decouple for
//     free,
//   - needs no RVA: the provider classes are resolved through RTTI by name and
//     the vtable comes from a throwaway instance, so it survives game patches.
//
// The provider vtable slot that returns the aim is slot 33 on this build. Slots
// [3..50] are instrumented with counting thunks so the slot can be re-confirmed
// from the log after a patch (see the `[AimProvider] slots` heartbeat).

#include "AimProviderHook.hpp"

#include <RED4ext/RED4ext.hpp>

#include <Windows.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "NativeRunningHook.hpp"
#include "QuatMath.hpp"
#include "ChaseCameraHook.hpp"
#include "ScriptChannel.hpp"
#include "SharedState.hpp"

extern SharedState g_sharedState;

void LogInfo(const char* fmt, ...);
void LogWarning(const char* fmt, ...);
void LogError(const char* fmt, ...);

namespace {

// Provider classes the launch chain instantiates. entFunc is the one the
// player's gun uses, entEntity shows up for grenades / thrown weapons,
// entStatic is instantiated by mods and by a few scripted attacks.
constexpr int         kClassCount = 3;
const char* const     kClassNames[kClassCount] = {
    "entEntityOrientationProvider",
    "entStaticOrientationProvider",
    "entFuncOrientationProvider",
};

constexpr int kSlotLo    = 3;                 // first vtable slot instrumented
constexpr int kSlotCount = 48;                // slots [3..50]
constexpr int kAimSlot   = 33;                // the slot that returns the aim orientation
constexpr int kAimIndex  = kAimSlot - kSlotLo;

// Provider output is accepted as "the player's aim" when it lines up with the
// FPP camera world orientation. 0.98 on the quaternion dot is ~23 degrees of
// full-angle slack, which swallows weapon spread and sway while still rejecting
// an NPC pointing somewhere else.
constexpr float kCamMatchDot = 0.98f;

// entIPlacedComponent: localTransform.Orientation @ +0xD0, worldTransform
// .Orientation @ +0xF0. g_camOrientationOffset is the local one.
constexpr int kWorldOrientationDelta = 0x20;

// Peel modes (SharedState::provider_mode, written by Lua).
enum Mode : uint32_t {
    kModeOff        = 0,  // instrument only
    kModeCamGated   = 1,  // peel when the provider answer matches the camera (ship)
    kModeLmbGated   = 2,  // peel while LMB is held (diagnostic)
    kModeAlways     = 3,  // peel every call (diagnostic)
    kModeDoubled    = 4,  // apply the head rotation AGAIN (sign sanity check)
};

// ---------------------------------------------------------------------------
// Counting thunks
//
// Instrumenting 144 vtable slots with C++ stubs would be a bet that none of
// them takes more than four arguments - a stub that forwards only the register
// arguments corrupts the stack arguments of anything wider. A hand-emitted
// `inc [counter]; jmp [orig]` thunk keeps the caller's frame completely intact,
// so counting is safe on every slot regardless of signature. Only the one slot
// we actually rewrite gets a C++ stub.
// ---------------------------------------------------------------------------
constexpr int kThunkCount = kClassCount * kSlotCount;
constexpr int kThunkSize  = 16;

struct ThunkPage {
    uint64_t counters[kThunkCount];
    uint64_t origs[kThunkCount];
    uint8_t  code[kThunkCount * kThunkSize];
};

ThunkPage* s_page = nullptr;

// inc qword ptr [rip+disp32] ; jmp qword ptr [rip+disp32]
void EmitThunk(uint8_t* code, uint64_t* counter, uint64_t* orig) {
    uint8_t* p = code;
    *p++ = 0x48; *p++ = 0xFF; *p++ = 0x05;
    int32_t rel = static_cast<int32_t>(reinterpret_cast<uint8_t*>(counter) - (p + 4));
    std::memcpy(p, &rel, 4); p += 4;
    *p++ = 0xFF; *p++ = 0x25;
    rel = static_cast<int32_t>(reinterpret_cast<uint8_t*>(orig) - (p + 4));
    std::memcpy(p, &rel, 4); p += 4;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
std::atomic<bool>     s_installed{false};
uintptr_t             s_vtables[kClassCount] = {0, 0, 0};
void*                 s_aimOrig[kClassCount] = {nullptr, nullptr, nullptr};

std::atomic<uint32_t> s_mode{kModeCamGated};
std::atomic<uint32_t> s_aimCalls{0};
std::atomic<uint32_t> s_overrides{0};
std::atomic<uint32_t> s_rejectedNoMatch{0};
std::atomic<uint32_t> s_rejectedIdentity{0};
uint32_t              s_logged = 0;
uint64_t              s_lastHeartbeatMs = 0;
uint64_t              s_lastLogMs = 0;
bool                  s_haveLogged = false;
uint32_t              s_loggedMode = 0;
uint32_t              s_loggedAimCalls = 0;
uint32_t              s_loggedOverrides = 0;
uint32_t              s_loggedNoMatch = 0;
uint32_t              s_loggedIdentity = 0;
int                   s_loggedTop[3] = {-1, -1, -1};
// Whether each counter was MOVING at the last reported line, not its value.
bool                  s_loggedMoving[4] = {false, false, false, false};

using quatmath::QuatMul;

// What ApplyPeel wants to tell the log, filled inside the SEH region so the
// logging call itself stays outside it.
struct PeelTrace {
    float in[4];
    float out[4];
    float camWorld[4];
    float dotRaw;
    float dotPeeled;
    bool  haveCam;
    bool  applied;
};

// Rewrites the provider's out-quat in place. POD-only body: it runs under SEH
// and must not need unwinding.
bool ApplyPeel(uintptr_t outp, uint32_t mode, PeelTrace& t) {
    t.haveCam = false;
    t.applied = false;
    t.dotRaw = 0.0f;
    t.dotPeeled = 0.0f;

    const float hx = g_headQuat[0], hy = g_headQuat[1];
    const float hz = g_headQuat[2], hw = g_headQuat[3];
    const float hLenSq = hx*hx + hy*hy + hz*hz + hw*hw;
    const float headDelta = std::fabs(hx) + std::fabs(hy) + std::fabs(hz) +
                            std::fabs(1.0f - std::fabs(hw));
    const HeadTrackingState state = g_sharedState.Read();
    const bool positionActive = state.aim_distance > 0.001f &&
        (std::fabs(state.position_x) + std::fabs(state.position_y) +
         std::fabs(state.position_z)) > 0.00001f;
    if (!std::isfinite(hLenSq) || hLenSq < 0.5f || hLenSq > 1.5f ||
        (headDelta < 0.005f && !positionActive)) {
        s_rejectedIdentity.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    // Lua writes cam.localOrientation = clean * head_quat (modules/camera.lua),
    // and the provider answers with that composition carried into world space.
    // Head rotation therefore sits on the RIGHT, so right-multiplying by its
    // inverse peels it regardless of what the parent transform contributes.
    const float ihx = (mode == kModeDoubled) ?  hx : -hx;
    const float ihy = (mode == kModeDoubled) ?  hy : -hy;
    const float ihz = (mode == kModeDoubled) ?  hz : -hz;
    const float ihw = hw;

    __try {
        float* q = reinterpret_cast<float*>(outp);
        const float qx = q[0], qy = q[1], qz = q[2], qw = q[3];
        const float qLenSq = qx*qx + qy*qy + qz*qz + qw*qw;
        if (!std::isfinite(qLenSq) || qLenSq < 0.9f || qLenSq > 1.1f) {
            return false;
        }
        t.in[0] = qx; t.in[1] = qy; t.in[2] = qz; t.in[3] = qw;

        float nx, ny, nz, nw;
        QuatMul(qx, qy, qz, qw, ihx, ihy, ihz, ihw, nx, ny, nz, nw);
        const float nLenSq = nx*nx + ny*ny + nz*nz + nw*nw;
        if (!std::isfinite(nLenSq) || nLenSq < 0.01f) {
            return false;
        }
        const float invLen = 1.0f / std::sqrt(nLenSq);
        nx *= invLen; ny *= invLen; nz *= invLen; nw *= invLen;

        if (positionActive) {
            const float tx = -state.position_x;
            const float ty = state.aim_distance + state.position_y;
            const float tz = -state.position_z;
            const float targetLenSq = tx*tx + ty*ty + tz*tz;
            if (std::isfinite(targetLenSq) && targetLenSq > 0.0001f) {
                const float targetInvLen = 1.0f / std::sqrt(targetLenSq);
                const float dx = tx * targetInvLen;
                const float dy = ty * targetInvLen;
                const float dz = tz * targetInvLen;

                // Shortest-arc quaternion from local +Y to the translated
                // target direction: cross(+Y, d), 1 + dot(+Y, d).
                float px = dz;
                float py = 0.0f;
                float pz = -dx;
                float pw = 1.0f + dy;
                const float pLenSq = px*px + py*py + pz*pz + pw*pw;
                if (std::isfinite(pLenSq) && pLenSq > 0.0001f) {
                    const float pInvLen = 1.0f / std::sqrt(pLenSq);
                    px *= pInvLen; py *= pInvLen; pz *= pInvLen; pw *= pInvLen;
                    float ox, oy, oz, ow;
                    QuatMul(nx, ny, nz, nw, px, py, pz, pw, ox, oy, oz, ow);
                    nx = ox; ny = oy; nz = oz; nw = ow;
                }
            }
        }

        // Is this the player's own aim? Compare against the camera's world
        // orientation both before and after the peel: whether the engine has
        // already folded our head rotation into the camera's world transform
        // this frame decides which of the two lines up.
        //
        // Which camera matters. In the vehicle chase camera the first-person
        // camera is not what is on screen and stays clean, so an aim quat
        // carrying the head rotation drifts away from it as the head moves,
        // the dot falls under the gate, and the peel switches itself off for
        // exactly the frames it is needed.
        float c[4];
        bool haveC = false;
        if (ScriptChannel_ChaseCameraActive()) {
            haveC = ChaseCameraHook_WorldOrientation(c);
        }
        if (!haveC) {
            void* cam = g_camInstance;
            const int camOff = g_camOrientationOffset;
            if (cam && camOff >= 0) {
                const float* src = reinterpret_cast<const float*>(
                    reinterpret_cast<uint8_t*>(cam) + camOff + kWorldOrientationDelta);
                c[0] = src[0]; c[1] = src[1]; c[2] = src[2]; c[3] = src[3];
                haveC = true;
            }
        }
        if (haveC) {
            const float cLenSq = c[0]*c[0] + c[1]*c[1] + c[2]*c[2] + c[3]*c[3];
            if (std::isfinite(cLenSq) && cLenSq > 0.9f && cLenSq < 1.1f) {
                t.camWorld[0] = c[0]; t.camWorld[1] = c[1];
                t.camWorld[2] = c[2]; t.camWorld[3] = c[3];
                t.haveCam = true;
                t.dotRaw = std::fabs(qx*c[0] + qy*c[1] + qz*c[2] + qw*c[3]);
                t.dotPeeled = std::fabs(nx*c[0] + ny*c[1] + nz*c[2] + nw*c[3]);
            }
        }

        bool gateOpen = false;
        switch (mode) {
        case kModeCamGated:
            gateOpen = t.haveCam && (t.dotRaw > kCamMatchDot || t.dotPeeled > kCamMatchDot);
            break;
        case kModeLmbGated:
            gateOpen = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;
            break;
        case kModeAlways:
        case kModeDoubled:
            gateOpen = true;
            break;
        default:
            gateOpen = false;
            break;
        }
        if (!gateOpen) {
            s_rejectedNoMatch.fetch_add(1, std::memory_order_relaxed);
            return false;
        }

        q[0] = nx; q[1] = ny; q[2] = nz; q[3] = nw;
        t.out[0] = nx; t.out[1] = ny; t.out[2] = nz; t.out[3] = nw;
        t.applied = true;
        s_overrides.fetch_add(1, std::memory_order_relaxed);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

template <int C>
uintptr_t __fastcall AimStub(uintptr_t rcx, uintptr_t rdx, uintptr_t r8, uintptr_t r9) {
    using Fn = uintptr_t(__fastcall*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t);
    Fn orig = reinterpret_cast<Fn>(s_aimOrig[C]);
    const uintptr_t ret = orig ? orig(rcx, rdx, r8, r9) : 0;

    s_aimCalls.fetch_add(1, std::memory_order_relaxed);

    const uint32_t mode = s_mode.load(std::memory_order_relaxed);
    if (mode == kModeOff) {
        return ret;
    }

    // The answer lands in the caller's buffer (rdx) on this build; a provider
    // that returns the quaternion instead hands it back in rax.
    const uintptr_t outp = rdx ? rdx : ret;
    if (!outp) {
        return ret;
    }

    PeelTrace trace{};
    const bool applied = ApplyPeel(outp, mode, trace);

    if (s_logged < 12 && (applied || trace.haveCam)) {
        ++s_logged;
        LogInfo("[AimProvider] cls=%s in=(%+.4f,%+.4f,%+.4f,%+.4f) out=(%+.4f,%+.4f,%+.4f,%+.4f) "
                "camWorld=(%+.4f,%+.4f,%+.4f,%+.4f) dotRaw=%.4f dotPeeled=%.4f applied=%d",
                kClassNames[C],
                trace.in[0], trace.in[1], trace.in[2], trace.in[3],
                trace.out[0], trace.out[1], trace.out[2], trace.out[3],
                trace.camWorld[0], trace.camWorld[1], trace.camWorld[2], trace.camWorld[3],
                trace.dotRaw, trace.dotPeeled, applied ? 1 : 0);
    }

    return ret;
}

void* AimStubFor(int c) {
    switch (c) {
    case 0: return reinterpret_cast<void*>(&AimStub<0>);
    case 1: return reinterpret_cast<void*>(&AimStub<1>);
    default: return reinterpret_cast<void*>(&AimStub<2>);
    }
}

bool InstallClass(RED4ext::CRTTISystem* rtti, int c) {
    RED4ext::CClass* cls = rtti->GetClass(RED4ext::CName(kClassNames[c]));
    if (!cls) {
        LogWarning("[AimProvider] class %s not found in RTTI", kClassNames[c]);
        return false;
    }
    void* inst = cls->CreateInstance(true);
    if (!inst) {
        LogWarning("[AimProvider] CreateInstance failed for %s", kClassNames[c]);
        return false;
    }

    uintptr_t vt = 0;
    __try {
        vt = *reinterpret_cast<uintptr_t*>(inst);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        vt = 0;
    }
    if (!vt) {
        LogWarning("[AimProvider] %s instance has no vtable", kClassNames[c]);
        return false;
    }

    // A second provider class can share a vtable with one already patched
    // (identical native implementation); patching it twice would chain our own
    // thunk into itself.
    for (int i = 0; i < c; ++i) {
        if (s_vtables[i] == vt) {
            LogInfo("[AimProvider] %s shares the vtable of %s - already instrumented",
                    kClassNames[c], kClassNames[i]);
            s_vtables[c] = vt;
            return true;
        }
    }

    uintptr_t* slot0 = reinterpret_cast<uintptr_t*>(vt + kSlotLo * sizeof(void*));
    DWORD oldProtect = 0;
    if (!VirtualProtect(slot0, kSlotCount * sizeof(void*), PAGE_EXECUTE_READWRITE, &oldProtect)) {
        LogError("[AimProvider] VirtualProtect failed for %s vtable", kClassNames[c]);
        return false;
    }

    for (int i = 0; i < kSlotCount; ++i) {
        const int idx = c * kSlotCount + i;
        uintptr_t* slot = reinterpret_cast<uintptr_t*>(vt + (kSlotLo + i) * sizeof(void*));
        s_page->origs[idx] = *slot;
        if (i == kAimIndex) {
            s_aimOrig[c] = reinterpret_cast<void*>(*slot);
            *slot = reinterpret_cast<uintptr_t>(AimStubFor(c));
        } else {
            *slot = reinterpret_cast<uintptr_t>(s_page->code + idx * kThunkSize);
        }
    }

    DWORD ignored = 0;
    VirtualProtect(slot0, kSlotCount * sizeof(void*), oldProtect, &ignored);
    s_vtables[c] = vt;
    LogInfo("[AimProvider] instrumented %s vtable=%p slots [%d..%d], aim stub on slot %d",
            kClassNames[c], reinterpret_cast<void*>(vt), kSlotLo, kSlotLo + kSlotCount - 1, kAimSlot);
    return true;
}

bool Install() {
    auto* rtti = RED4ext::CRTTISystem::Get();
    if (!rtti) return false;
    // Nothing to instrument until the class registry is populated.
    if (!rtti->GetClass(RED4ext::CName(kClassNames[kClassCount - 1]))) return false;

    // Install() is retried from every OnUpdate until it takes. Allocating the
    // page here unconditionally leaked a 64 KB executable reservation per frame
    // whenever the classes were up but instrumentation failed, so the page is
    // allocated once and freed again if this attempt instruments nothing.
    if (!s_page) {
        s_page = static_cast<ThunkPage*>(VirtualAlloc(nullptr, sizeof(ThunkPage),
                                                      MEM_RESERVE | MEM_COMMIT,
                                                      PAGE_EXECUTE_READWRITE));
        if (!s_page) {
            LogError("[AimProvider] thunk page allocation failed");
            return false;
        }
        std::memset(s_page, 0, sizeof(ThunkPage));
        for (int i = 0; i < kThunkCount; ++i) {
            EmitThunk(s_page->code + i * kThunkSize, &s_page->counters[i], &s_page->origs[i]);
        }
        FlushInstructionCache(GetCurrentProcess(), s_page->code, sizeof(s_page->code));
    }

    int ok = 0;
    for (int c = 0; c < kClassCount; ++c) {
        if (InstallClass(rtti, c)) ++ok;
    }
    if (ok == 0) {
        LogError("[AimProvider] no provider class instrumented");
        VirtualFree(s_page, 0, MEM_RELEASE);
        s_page = nullptr;
        return false;
    }
    LogInfo("[AimProvider] installed on %d/%d provider classes", ok, kClassCount);
    return true;
}

void Heartbeat() {
    const uint64_t now = GetTickCount64();
    if (s_lastHeartbeatMs != 0 && now - s_lastHeartbeatMs < 5000) return;
    s_lastHeartbeatMs = now;

    // Busiest instrumented slots, so the aim slot can be re-identified from a
    // log after a patch moves it.
    int    topIdx[3] = {-1, -1, -1};
    uint64_t topVal[3] = {0, 0, 0};
    for (int i = 0; i < kThunkCount; ++i) {
        const uint64_t v = s_page->counters[i];
        if (v == 0) continue;
        for (int k = 0; k < 3; ++k) {
            if (v > topVal[k]) {
                for (int j = 2; j > k; --j) { topVal[j] = topVal[j-1]; topIdx[j] = topIdx[j-1]; }
                topVal[k] = v; topIdx[k] = i;
                break;
            }
        }
    }

    char slots[192];
    size_t written = 0;
    slots[0] = '\0';
    for (int k = 0; k < 3 && topIdx[k] >= 0; ++k) {
        if (written + 1 >= sizeof(slots)) break;
        const int c = topIdx[k] / kSlotCount;
        const int s = topIdx[k] % kSlotCount + kSlotLo;
        // _snprintf_s returns -1 on truncation; folding that into `written`
        // walked the offset backwards and then handed the next iteration a
        // wrapped (huge) size_t buffer size.
        const int n = _snprintf_s(slots + written, sizeof(slots) - written, _TRUNCATE,
                                  "%s%s:%d=%llu", written ? " " : "", kClassNames[c], s,
                                  static_cast<unsigned long long>(topVal[k]));
        if (n < 0) break;
        written += static_cast<size_t>(n);
    }

    // Until the player fires, every counter here sits still and the busiest
    // slots do not move, so a plain 5s heartbeat repeated one dead line for the
    // whole session - 21% of the log. Once the player DOES fire the counters
    // move every window, so comparing their values instead reported every 5s
    // for the length of the firefight. Report what a reader actually acts on:
    // the mode, the top slot INDICES (what re-identifies the aim slot after a
    // patch), and whether each counter is moving at all. A 5-minute liveness
    // line keeps a quiet log proving the hook is still installed.
    const uint32_t mode      = s_mode.load(std::memory_order_relaxed);
    const uint32_t aimCalls  = s_aimCalls.load(std::memory_order_relaxed);
    const uint32_t overrides = s_overrides.load(std::memory_order_relaxed);
    const uint32_t noMatch   = s_rejectedNoMatch.load(std::memory_order_relaxed);
    const uint32_t identity  = s_rejectedIdentity.load(std::memory_order_relaxed);
    const bool moving[4] = {aimCalls  != s_loggedAimCalls,
                            overrides != s_loggedOverrides,
                            noMatch   != s_loggedNoMatch,
                            identity  != s_loggedIdentity};
    const bool changed = !s_haveLogged ||
                         mode != s_loggedMode ||
                         moving[0] != s_loggedMoving[0] ||
                         moving[1] != s_loggedMoving[1] ||
                         moving[2] != s_loggedMoving[2] ||
                         moving[3] != s_loggedMoving[3] ||
                         topIdx[0] != s_loggedTop[0] ||
                         topIdx[1] != s_loggedTop[1] ||
                         topIdx[2] != s_loggedTop[2];
    // Counters are rebased on every pass so `moving` describes the window just
    // closed; only the reported snapshot is held back to the emitted line.
    s_loggedAimCalls = aimCalls;
    s_loggedOverrides = overrides;
    s_loggedNoMatch = noMatch;
    s_loggedIdentity = identity;
    if (!changed && now - s_lastLogMs < 300000) return;

    LogInfo("[AimProvider] heartbeat: mode=%u aimCalls=%u overrides=%u noMatch=%u identity=%u slots[%s]",
            mode, aimCalls, overrides, noMatch, identity, slots);

    s_lastLogMs = now;
    s_haveLogged = true;
    s_loggedMode = mode;
    s_loggedMoving[0] = moving[0];
    s_loggedMoving[1] = moving[1];
    s_loggedMoving[2] = moving[2];
    s_loggedMoving[3] = moving[3];
    s_loggedTop[0] = topIdx[0];
    s_loggedTop[1] = topIdx[1];
    s_loggedTop[2] = topIdx[2];
}

}  // namespace

bool AimProviderHook_Tick() {
    if (!s_installed.load(std::memory_order_acquire)) {
        // RTTI comes up well after plugin load; retry until it does.
        if (!Install()) return false;
        s_installed.store(true, std::memory_order_release);
    }

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        s_mode.store(w->provider_mode, std::memory_order_relaxed);
        w->provider_hook_active = 1;
        w->provider_calls = s_aimCalls.load(std::memory_order_relaxed);
        w->provider_overrides = s_overrides.load(std::memory_order_relaxed);
    }

    Heartbeat();
    return true;
}

void AimProviderHook_Stop() {
    if (!s_installed.exchange(false, std::memory_order_acq_rel)) return;

    for (int c = 0; c < kClassCount; ++c) {
        const uintptr_t vt = s_vtables[c];
        if (!vt) continue;
        bool duplicate = false;
        for (int i = 0; i < c; ++i) if (s_vtables[i] == vt) duplicate = true;
        if (duplicate) continue;

        uintptr_t* slot0 = reinterpret_cast<uintptr_t*>(vt + kSlotLo * sizeof(void*));
        DWORD oldProtect = 0;
        if (!VirtualProtect(slot0, kSlotCount * sizeof(void*), PAGE_EXECUTE_READWRITE, &oldProtect)) continue;
        for (int i = 0; i < kSlotCount; ++i) {
            uintptr_t* slot = reinterpret_cast<uintptr_t*>(vt + (kSlotLo + i) * sizeof(void*));
            *slot = s_page->origs[c * kSlotCount + i];
        }
        DWORD ignored = 0;
        VirtualProtect(slot0, kSlotCount * sizeof(void*), oldProtect, &ignored);
        s_vtables[c] = 0;
    }

    LogInfo("[AimProvider] vtables restored");
}

bool AimProviderHook_IsActive() {
    return s_installed.load(std::memory_order_acquire);
}
