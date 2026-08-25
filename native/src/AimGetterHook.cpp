// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
// AimGetterHook - decouple the bullet by rewriting the camera ANSWER the shot
// receives, never the camera itself.
//
// Every earlier attempt wrote to shared camera state (cam+0xD0, the shooter
// state aim quat at +0x1E30, the trace ray) and lost the same way: the engine
// round-trips those values back into the camera, so a clean bullet always came
// with a de-tracked view. The single-shot Lua SNAP-CLEAN worked around it by
// flicking the camera for one frame, which is why automatic fire sprays at
// screen centre - only the first round of a trigger pull gets the flick.
//
// The seam this uses instead: the shot does not read the camera struct, it
// CALLS for the camera and gets the answer in a buffer it owns. Rewriting that
// buffer decouples the round with nothing to restore, and because the calls
// happen per round, sustained fire decouples exactly like a single shot.
//
// Levers (all confirmed present in this build's EXE by opcode, see the RVA
// notes in AimGetterHook.hpp):
//   A +0x802390 GetWorldOrientation - out quat in rdx.
//   B +0x1D92A0 GetWorldTransform   - out orientation at r8+0x10.
//   C +0x84C968 the weapon-fire routine's `dir = Normalize(target - muzzle)`
//               call site, patched to route through us so the resulting shot
//               direction can be rotated back to the mouse.
//
// A and B hand back the camera world orientation, so the peel is the same
// right-multiplication by inv(head) the Lua side uses. C hands back a WORLD
// direction, so the head rotation has to be conjugated into world space first
// (see PeelWorldDirection).

#include "AimGetterHook.hpp"

#include <Windows.h>
#include <intrin.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstdio>

#include "ModuleGuard.hpp"
#include "NativeRunningHook.hpp"
#include "QuatMath.hpp"
#include "ChaseCameraHook.hpp"
#include "ScriptChannel.hpp"
#include "SharedState.hpp"
#include "builds/build_registry.hpp"

extern SharedState g_sharedState;

void LogInfo(const char* fmt, ...);
void LogWarning(const char* fmt, ...);
void LogError(const char* fmt, ...);

namespace {

// Projectile launch-state setup, found by capturing the return address in the
// aim provider stub (the provider is called from inside it via vtable slot 33 /
// +0x108). param_1 is the launch state: providers at +0x600 logical position,
// +0x610 logical orientation, +0x620 visual position, +0x630 visual orientation,
// poses written into +0x480..+0x520.
//
// Dumping that object is how we find where the launch SPEED lives. Everything
// else has been eliminated: the round is not Attacks.Bullet_Projectile, has no
// scripted layer (BaseBullet / BaseProjectile / launch helpers all observed
// across hundreds of rounds, never fired), and the velocity params are not
// reachable from the provider's stack.

// All four addresses come from the matched build profile - see
// builds/build_profile.h. They are zero on a build we have not derived them
// against, and each lever checks for that before it touches anything.
inline uintptr_t GetWorldOrientationRva() { return builds::ActiveProfile().Offsets.GetWorldOrientation; }
inline uintptr_t SmartGunCallARva() { return builds::ActiveProfile().Offsets.SmartGunCameraCallA; }
inline uintptr_t SmartGunCallBRva() { return builds::ActiveProfile().Offsets.SmartGunCameraCallB; }
inline uintptr_t GetWorldTransformRva()   { return builds::ActiveProfile().Offsets.GetWorldTransform; }
inline uintptr_t FireNormaliseCallRva()   { return builds::ActiveProfile().Offsets.FireNormaliseCall; }
inline uintptr_t NormaliseFnRva()         { return builds::ActiveProfile().Offsets.NormaliseFn; }

// entIPlacedComponent worldTransform.Orientation, relative to the local
// orientation offset the cam resolver already found (+0xD0 -> +0xF0).
constexpr int kWorldOrientationDelta = 0x20;

// A/B hand back a verbatim copy of a camera orientation, so the match against
// our own camera is exact up to float noise.
constexpr float kCamMatchDot = 0.9995f;
// C hands back a spread-perturbed shot direction. The cone has to stay wide
// enough to still recognise our own shot when the camera orientation we compare
// against carries a different amount of head rotation than the direction does
// (that is exactly what the heartbeat's head/local/world dump resolves), so
// 0.6 - about 53 degrees - not the tight match A and B can afford.
constexpr float kDirMatchDot = 0.6f;

// Trigger-release grace: the fire routine can run a frame or two after the
// button comes up.
constexpr uint64_t kFireWindowMs = 300;

enum Mode : uint32_t {
    kModeOff        = 0,
    kModeInstrument = 1,  // hooks live, counters only
    kModePeelA      = 2,
    kModePeelB      = 3,
    kModePeelC      = 4,
    // Discriminator: rotate lever A's answer by a large fixed yaw, independent
    // of the tracker. With no head pose the view stays still, so if the impacts
    // swing wide then this getter really is what aims the bullet. Peeling by the
    // head pose cannot answer that on its own - a null result there is
    // indistinguishable from a lever the shot ignores.
    kModeTestYawA   = 5,
};

// Deliberately large: unmistakable on camera, still on a wide wall.
constexpr float kTestYawRadians = 0.785398f;  // 45 degrees

std::atomic<uint32_t> s_mode{kModeInstrument};

// Caller histogram for the camera-orientation answers (instrument mode).
//
// Every consumer that asks for the camera orientation shows up here as the RVA
// of its call site, so a system whose behaviour follows the head - the smart
// weapon targeting cone, for one - can be identified by equipping the weapon
// that drives it and reading which call site appears. Only calls whose answer
// actually WAS the camera orientation (dot >= kCamMatchDot) are recorded, which
// cuts the generic transform getter's half a million calls a second down to the
// handful that matter. Counts are per heartbeat window so the log reads as
// "who asked in the last 30 seconds", making an A/B by equipped weapon legible.
constexpr size_t kCallerSlots = 48;
struct CallerSlot {
    std::atomic<uintptr_t> rva{0};
    std::atomic<uint32_t>  hits{0};
};
CallerSlot s_callersA[kCallerSlots];
CallerSlot s_callersB[kCallerSlots];

void RecordCaller(CallerSlot* table, void* returnAddress) {
    const uintptr_t base = modguard::ExeBase();
    if (!base || !returnAddress) return;
    const uintptr_t addr = reinterpret_cast<uintptr_t>(returnAddress);
    if (addr < base) return;
    const uintptr_t rva = addr - base;

    for (size_t probe = 0; probe < kCallerSlots; ++probe) {
        const size_t i = (static_cast<size_t>(rva >> 4) + probe) % kCallerSlots;
        uintptr_t held = table[i].rva.load(std::memory_order_relaxed);
        if (held == rva) {
            table[i].hits.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        if (held == 0) {
            uintptr_t expected = 0;
            if (table[i].rva.compare_exchange_strong(expected, rva,
                                                     std::memory_order_relaxed)) {
                table[i].hits.fetch_add(1, std::memory_order_relaxed);
                return;
            }
            if (table[i].rva.load(std::memory_order_relaxed) == rva) {
                table[i].hits.fetch_add(1, std::memory_order_relaxed);
                return;
            }
        }
    }
    // Table full: the window's picture is already complete enough to read.
}

// Rank the busiest call sites this window, then clear so the next window
// stands on its own.
constexpr int kCallerRanks = 8;

struct CallerCensus {
    uintptr_t rva[kCallerRanks] = {0};
    uint32_t  hits[kCallerRanks] = {0};
    int       count = 0;
};

CallerCensus DrainCallers(CallerSlot* table) {
    CallerCensus census;
    for (int rank = 0; rank < kCallerRanks; ++rank) {
        size_t best = kCallerSlots;
        uint32_t bestHits = 0;
        for (size_t i = 0; i < kCallerSlots; ++i) {
            const uint32_t hits = table[i].hits.load(std::memory_order_relaxed);
            if (hits > bestHits) { bestHits = hits; best = i; }
        }
        if (best == kCallerSlots) break;
        census.rva[census.count]  = table[best].rva.load(std::memory_order_relaxed);
        census.hits[census.count] = bestHits;
        ++census.count;
        table[best].hits.store(0, std::memory_order_relaxed);
        table[best].rva.store(0, std::memory_order_relaxed);
    }
    for (size_t i = 0; i < kCallerSlots; ++i) {
        table[i].hits.store(0, std::memory_order_relaxed);
        table[i].rva.store(0, std::memory_order_relaxed);
    }
    return census;
}

// The census is a reverse-engineering instrument, so it earns a line in a
// shipped log only when it says something new. The busiest call sites settle
// within seconds of entering gameplay and then repeat for the rest of the
// session. Compare the RANKED RVAs and stay silent while they hold; the hit
// counts move every window and would defeat the gate.
bool SameCallers(const CallerCensus& a, const CallerCensus& b) {
    if (a.count != b.count) return false;
    for (int i = 0; i < a.count; ++i) {
        if (a.rva[i] != b.rva[i]) return false;
    }
    return true;
}

void LogCallers(const char* label, const CallerCensus& census) {
    char line[512];
    int  used = 0;
    line[0] = 0;
    for (int i = 0; i < census.count; ++i) {
        const int written = snprintf(line + used, sizeof(line) - used,
                                     "%s+0x%llX=%u", used ? " " : "",
                                     (unsigned long long)census.rva[i], census.hits[i]);
        if (written <= 0 || used + written >= (int)sizeof(line)) break;
        used += written;
    }
    if (used > 0) LogInfo("[AimGetter] %s callers: %s", label, line);
}

std::atomic<uint32_t> s_smartGunPeels{0};
std::atomic<uint32_t> s_callsA{0}, s_callsB{0}, s_callsC{0};
std::atomic<uint32_t> s_matchA{0}, s_matchB{0}, s_matchC{0};
std::atomic<uint32_t> s_overrides{0};
uint32_t              s_loggedA = 0, s_loggedB = 0, s_loggedC = 0;
uint64_t              s_lastWindowMs = 0;
uint32_t              s_lastCallsA = 0, s_lastCallsB = 0, s_lastCallsC = 0;
uint32_t              s_lastMode = 0xFFFFFFFFu;
uint64_t              s_lastLiveLogMs = 0;
bool                  s_lastMoving[3] = {false, false, false};
CallerCensus          s_lastCensusA, s_lastCensusB;

using GetWorldOrientationFn = void* (*)(void*, void*);
using GetWorldTransformFn   = uintptr_t (*)(void*, void*, void*);
using NormaliseFn           = void* (*)(float*, float*);

void*                 s_targetA  = nullptr;
void*                 s_targetB  = nullptr;
GetWorldOrientationFn s_origA    = nullptr;
GetWorldTransformFn   s_origB    = nullptr;
NormaliseFn           s_origC    = nullptr;

uint8_t* s_callsite     = nullptr;
uint8_t  s_callsiteOrig[5] = {0};
uint8_t* s_relay        = nullptr;

std::atomic<bool> s_started{false};

using quatmath::QuatMul;

// v' = q * v * conj(q), q = (x, y, z, w)
inline void RotateVec(const float* q, const float* v, float* o) {
    const float x = q[0], y = q[1], z = q[2], w = q[3];
    const float tx = 2.0f * (y*v[2] - z*v[1]);
    const float ty = 2.0f * (z*v[0] - x*v[2]);
    const float tz = 2.0f * (x*v[1] - y*v[0]);
    o[0] = v[0] + w*tx + (y*tz - z*ty);
    o[1] = v[1] + w*ty + (z*tx - x*tz);
    o[2] = v[2] + w*tz + (x*ty - y*tx);
}

// The head rotation Lua right-multiplied onto cam.localOrientation this frame.
// Returns false when tracking is idle, in which case there is nothing to peel.
bool ReadHead(float* head) {
    head[0] = g_headQuat[0]; head[1] = g_headQuat[1];
    head[2] = g_headQuat[2]; head[3] = g_headQuat[3];
    const float lenSq = head[0]*head[0] + head[1]*head[1] + head[2]*head[2] + head[3]*head[3];
    if (!std::isfinite(lenSq) || lenSq < 0.5f || lenSq > 1.5f) return false;
    const float delta = std::fabs(head[0]) + std::fabs(head[1]) + std::fabs(head[2]) +
                        std::fabs(1.0f - std::fabs(head[3]));
    return delta >= 0.005f;
}

bool ReadCamWorld(float* out) {
    // The chase camera renders from its own object, so the first-person camera
    // read below is clean there and every comparison against it fails by the
    // head angle.
    if (ScriptChannel_ChaseCameraActive() && ChaseCameraHook_WorldOrientation(out)) {
        return true;
    }
    void* cam = g_camInstance;
    const int camOff = g_camOrientationOffset;
    if (!cam || camOff < 0) return false;
    bool ok = false;
    __try {
        const float* c = reinterpret_cast<const float*>(
            reinterpret_cast<uint8_t*>(cam) + camOff + kWorldOrientationDelta);
        const float lenSq = c[0]*c[0] + c[1]*c[1] + c[2]*c[2] + c[3]*c[3];
        if (std::isfinite(lenSq) && lenSq > 0.9f && lenSq < 1.1f) {
            out[0] = c[0]; out[1] = c[1]; out[2] = c[2]; out[3] = c[3];
            ok = true;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        ok = false;
    }
    return ok;
}

// LMB down, or released within the grace window.
bool InFireWindow() {
    static std::atomic<uint64_t> s_lastDownMs{0};
    const bool down = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;
    const uint64_t now = GetTickCount64();
    if (down) {
        s_lastDownMs.store(now, std::memory_order_relaxed);
        return true;
    }
    const uint64_t last = s_lastDownMs.load(std::memory_order_relaxed);
    return last != 0 && now - last <= kFireWindowMs;
}

// q is a camera world orientation carrying our head rotation on the right.
bool PeelCameraQuat(float* q, const float* head) {
    const float lenSq = q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3];
    if (!std::isfinite(lenSq) || lenSq < 0.9f || lenSq > 1.1f) return false;
    float nx, ny, nz, nw;
    QuatMul(q[0], q[1], q[2], q[3], -head[0], -head[1], -head[2], head[3], nx, ny, nz, nw);
    const float nLenSq = nx*nx + ny*ny + nz*nz + nw*nw;
    if (!std::isfinite(nLenSq) || nLenSq < 0.01f) return false;
    const float inv = 1.0f / std::sqrt(nLenSq);
    q[0] = nx*inv; q[1] = ny*inv; q[2] = nz*inv; q[3] = nw*inv;
    return true;
}

// d is a WORLD direction produced by the head-rotated camera. The head rotation
// lives in camera-local space, so it has to be conjugated through the camera
// basis: express d in the dirty camera's frame, then re-project it with the
// clean camera. Spread and muzzle offset survive because only the basis
// changes.
bool PeelWorldDirection(float* d, const float* head, const float* camWorld) {
    float clean[4];
    QuatMul(camWorld[0], camWorld[1], camWorld[2], camWorld[3],
            -head[0], -head[1], -head[2], head[3],
            clean[0], clean[1], clean[2], clean[3]);
    const float cLenSq = clean[0]*clean[0] + clean[1]*clean[1] + clean[2]*clean[2] + clean[3]*clean[3];
    if (!std::isfinite(cLenSq) || cLenSq < 0.01f) return false;
    const float cInv = 1.0f / std::sqrt(cLenSq);
    clean[0] *= cInv; clean[1] *= cInv; clean[2] *= cInv; clean[3] *= cInv;

    const float camConj[4] = { -camWorld[0], -camWorld[1], -camWorld[2], camWorld[3] };
    float local[3];
    RotateVec(camConj, d, local);
    float out[3];
    RotateVec(clean, local, out);
    const float lenSq = out[0]*out[0] + out[1]*out[1] + out[2]*out[2];
    if (!std::isfinite(lenSq) || lenSq < 0.01f) return false;
    const float inv = 1.0f / std::sqrt(lenSq);
    d[0] = out[0]*inv; d[1] = out[1]*inv; d[2] = out[2]*inv;
    return true;
}

bool ApplyPositionToWorldDirection(float* d, const float* head,
                                   const float* camWorld) {
    const HeadTrackingState state = g_sharedState.Read();
    if (state.aim_distance <= 0.001f ||
        std::fabs(state.position_x) + std::fabs(state.position_y) +
                std::fabs(state.position_z) <= 0.00001f) {
        return true;
    }

    float clean[4];
    QuatMul(camWorld[0], camWorld[1], camWorld[2], camWorld[3],
            -head[0], -head[1], -head[2], head[3],
            clean[0], clean[1], clean[2], clean[3]);
    const float cleanLenSq = clean[0]*clean[0] + clean[1]*clean[1] +
                             clean[2]*clean[2] + clean[3]*clean[3];
    if (!std::isfinite(cleanLenSq) || cleanLenSq < 0.01f) return false;
    const float cleanInv = 1.0f / std::sqrt(cleanLenSq);
    for (float& component : clean) component *= cleanInv;

    const float tx = -state.position_x;
    const float ty = state.aim_distance + state.position_y;
    const float tz = -state.position_z;
    const float targetLenSq = tx*tx + ty*ty + tz*tz;
    if (!std::isfinite(targetLenSq) || targetLenSq < 0.0001f) return false;
    const float targetInv = 1.0f / std::sqrt(targetLenSq);
    const float dx = tx * targetInv;
    const float dy = ty * targetInv;
    const float dz = tz * targetInv;
    float position[4] = {dz, 0.0f, -dx, 1.0f + dy};
    const float positionLenSq = position[0]*position[0] +
                                position[2]*position[2] +
                                position[3]*position[3];
    if (!std::isfinite(positionLenSq) || positionLenSq < 0.0001f) return false;
    const float positionInv = 1.0f / std::sqrt(positionLenSq);
    for (float& component : position) component *= positionInv;

    const float cleanConj[4] = {-clean[0], -clean[1], -clean[2], clean[3]};
    float local[3];
    RotateVec(cleanConj, d, local);
    float correctedLocal[3];
    RotateVec(position, local, correctedLocal);
    float correctedWorld[3];
    RotateVec(clean, correctedLocal, correctedWorld);
    const float outLenSq = correctedWorld[0]*correctedWorld[0] +
                           correctedWorld[1]*correctedWorld[1] +
                           correctedWorld[2]*correctedWorld[2];
    if (!std::isfinite(outLenSq) || outLenSq < 0.01f) return false;
    const float outInv = 1.0f / std::sqrt(outLenSq);
    d[0] = correctedWorld[0] * outInv;
    d[1] = correctedWorld[1] * outInv;
    d[2] = correctedWorld[2] * outInv;
    return true;
}

// Swing the answer by a fixed yaw about the world up axis (REDengine is Z-up).
bool ApplyTestYaw(float* q) {
    const float half = kTestYawRadians * 0.5f;
    const float yaw[4] = { 0.0f, 0.0f, std::sin(half), std::cos(half) };
    float out[4];
    QuatMul(yaw[0], yaw[1], yaw[2], yaw[3], q[0], q[1], q[2], q[3],
            out[0], out[1], out[2], out[3]);
    for (int i = 0; i < 4; ++i) q[i] = out[i];
    return true;
}

// Shared body for the two camera getters. Returns true when it rewrote the quat.
bool HandleCameraQuat(void* outQuat, bool peel, float* dotOut, bool testYaw = false) {
    *dotOut = 0.0f;
    if (!outQuat) return false;

    float head[4];
    if (!ReadHead(head)) return false;
    float camWorld[4];
    if (!ReadCamWorld(camWorld)) return false;

    bool rewrote = false;
    __try {
        float* q = reinterpret_cast<float*>(outQuat);
        const float dot = std::fabs(q[0]*camWorld[0] + q[1]*camWorld[1] +
                                    q[2]*camWorld[2] + q[3]*camWorld[3]);
        *dotOut = dot;
        if (dot < kCamMatchDot) return false;   // not our camera
        if (testYaw) {
            rewrote = ApplyTestYaw(q);
        } else {
            if (!peel) return false;
            rewrote = PeelCameraQuat(q, head);
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        rewrote = false;
    }
    if (rewrote) s_overrides.fetch_add(1, std::memory_order_relaxed);
    return rewrote;
}

// True when this camera-orientation answer is going to the smart weapon's
// targeting, which decides which enemies are inside its cone and holds the
// locks it already has.
//
// The cone is centred on whatever orientation it reads here. Head tracking
// turns the camera, so an unpeeled answer turns the cone with the player's
// head: an enemy they are still AIMING at leaves the cone as they look away
// and the game plays its unlock animation. Peeling here leaves the cone on the
// weapon's aim, where vanilla puts it, while the view stays free - the same
// separation the shot path already gets, applied to target selection.
bool IsSmartGunCameraRead(void* returnAddress) {
    const uintptr_t callA = SmartGunCallARva();
    const uintptr_t callB = SmartGunCallBRva();
    if (!callA && !callB) return false;
    const uintptr_t base = modguard::ExeBase();
    if (!base || !returnAddress) return false;
    const uintptr_t addr = reinterpret_cast<uintptr_t>(returnAddress);
    if (addr < base) return false;
    const uintptr_t rva = addr - base;
    return rva == callA || rva == callB;
}

void* Hook_GetWorldOrientation(void* rcx, void* rdx) {
    void* ret = s_origA ? s_origA(rcx, rdx) : nullptr;
    const uint32_t mode = s_mode.load(std::memory_order_relaxed);
    if (mode == kModeOff) return ret;

    s_callsA.fetch_add(1, std::memory_order_relaxed);
    // Every peel here exists to undo the head rotation composed into camera
    // state - by Lua in first person, by RenderNodeInject in the chase camera.
    // Not gated on the fire window: target selection runs every frame, and a
    // cone that only stops following the head while the trigger is down would
    // drop the locks the moment the player stops firing.
    const bool smartGun = IsSmartGunCameraRead(_ReturnAddress());
    const bool peel = smartGun || ((mode == kModePeelA) && InFireWindow());
    const bool testYaw = (mode == kModeTestYawA) && InFireWindow();
    float dot = 0.0f;
    const bool rewrote = HandleCameraQuat(rdx, peel, &dot, testYaw);
    if (dot >= kCamMatchDot) {
        s_matchA.fetch_add(1, std::memory_order_relaxed);
        RecordCaller(s_callersA, _ReturnAddress());
    }

    if (s_loggedA < 8 && dot >= kCamMatchDot) {
        ++s_loggedA;
        LogInfo("[AimGetter] A +0x802390 dot=%.5f peel=%d smartgun=%d rewrote=%d",
                dot, peel ? 1 : 0, smartGun ? 1 : 0, rewrote ? 1 : 0);
    }
    if (smartGun && rewrote) s_smartGunPeels.fetch_add(1, std::memory_order_relaxed);
    return ret;
}

uintptr_t Hook_GetWorldTransform(void* rcx, void* rdx, void* r8) {
    const uintptr_t ret = s_origB ? s_origB(rcx, rdx, r8) : 0;
    const uint32_t mode = s_mode.load(std::memory_order_relaxed);
    if (mode == kModeOff) return ret;

    s_callsB.fetch_add(1, std::memory_order_relaxed);
    const bool peel = (mode == kModePeelB) && InFireWindow();
    void* outQuat = r8 ? reinterpret_cast<uint8_t*>(r8) + 0x10 : nullptr;
    float dot = 0.0f;
    const bool rewrote = HandleCameraQuat(outQuat, peel, &dot);
    if (dot >= kCamMatchDot) {
        s_matchB.fetch_add(1, std::memory_order_relaxed);
        RecordCaller(s_callersB, _ReturnAddress());
    }

    if (s_loggedB < 8 && dot >= kCamMatchDot) {
        ++s_loggedB;
        LogInfo("[AimGetter] B +0x1D92A0 dot=%.5f peel=%d rewrote=%d", dot, peel ? 1 : 0, rewrote ? 1 : 0);
    }
    return ret;
}

// Stands in for the `Normalize(target - muzzle)` call inside the weapon-fire
// routine: run the real one, then rotate its result off the head and back onto
// the mouse.
void* Hook_FireNormalise(float* input, float* output) {
    void* ret = s_origC ? s_origC(input, output) : reinterpret_cast<void*>(output);
    const uint32_t mode = s_mode.load(std::memory_order_relaxed);
    if (mode == kModeOff || !output) return ret;

    s_callsC.fetch_add(1, std::memory_order_relaxed);

    float head[4], camWorld[4];
    if (!ReadHead(head) || !ReadCamWorld(camWorld)) return ret;

    bool rewrote = false;
    float dot = 0.0f;
    float before[3] = {0, 0, 0};
    __try {
        // RED world forward is +Y, so the camera forward is the quat applied to
        // (0, 1, 0). A shot fired by us leaves along it, give or take spread.
        const float fwdLocal[3] = {0.0f, 1.0f, 0.0f};
        float camFwd[3];
        RotateVec(camWorld, fwdLocal, camFwd);
        before[0] = output[0]; before[1] = output[1]; before[2] = output[2];
        const float lenSq = before[0]*before[0] + before[1]*before[1] + before[2]*before[2];
        if (std::isfinite(lenSq) && lenSq > 0.5f && lenSq < 2.0f) {
            dot = before[0]*camFwd[0] + before[1]*camFwd[1] + before[2]*camFwd[2];
            if (dot >= kDirMatchDot) {
                s_matchC.fetch_add(1, std::memory_order_relaxed);
                if (mode == kModePeelC && InFireWindow()) {
                    rewrote = PeelWorldDirection(output, head, camWorld);
                }
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        rewrote = false;
    }

    if (rewrote) s_overrides.fetch_add(1, std::memory_order_relaxed);
    if (s_loggedC < 12 && dot >= kDirMatchDot) {
        ++s_loggedC;
        LogInfo("[AimGetter] C +0x84C968 dot=%.4f in=(%+.4f,%+.4f,%+.4f) out=(%+.4f,%+.4f,%+.4f) rewrote=%d",
                dot, before[0], before[1], before[2],
                output[0], output[1], output[2], rewrote ? 1 : 0);
    }
    return ret;
}

// A call site cannot be detoured, so it gets rewritten to call a relay stub
// allocated within rel32 reach that jumps to us.
uint8_t* AllocRelayNear(uint8_t* target) {
    SYSTEM_INFO si{};
    GetSystemInfo(&si);
    const uintptr_t granularity = si.dwAllocationGranularity ? si.dwAllocationGranularity : 0x10000;
    const uintptr_t base = reinterpret_cast<uintptr_t>(target);
    for (uintptr_t dist = granularity; dist < 0x70000000ull; dist += granularity) {
        const uintptr_t candidates[2] = { base + dist, base > dist ? base - dist : 0 };
        for (uintptr_t c : candidates) {
            if (!c) continue;
            void* m = VirtualAlloc(reinterpret_cast<void*>(c & ~(granularity - 1)), granularity,
                                   MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
            if (m) return static_cast<uint8_t*>(m);
        }
    }
    return nullptr;
}

// Leave lever C fully disarmed: no call site to restore in Stop(), no relay
// page leaked. Always returns false so callers can `return` it directly.
bool AbandonCallsitePatch() {
    if (s_relay) {
        VirtualFree(s_relay, 0, MEM_RELEASE);
        s_relay = nullptr;
    }
    s_callsite = nullptr;
    s_origC = nullptr;
    return false;
}

bool PatchFireNormaliseCallsite() {
    // Bounds-check before the opcode read below: on a build whose image is
    // smaller than these RVAs, reading s_callsite[0] is an access violation at
    // plugin load, which the user sees as the mod bricking the game.
    const uintptr_t normalise = modguard::ResolveCodeRva(NormaliseFnRva(), 16, "AimGetter C (Normalize)");
    const uintptr_t callsite = modguard::ResolveCodeRva(FireNormaliseCallRva(), 5, "AimGetter C (call site)");
    if (!normalise || !callsite) return false;

    s_origC = reinterpret_cast<NormaliseFn>(normalise);
    s_callsite = reinterpret_cast<uint8_t*>(callsite);

    // Refuse on anything but the exact `call Normalize` this was derived
    // against - a moved call site means a patched game, and a blind write there
    // would corrupt whatever took its place.
    if (s_callsite[0] != 0xE8) {
        LogWarning("[AimGetter] C: +0x%llX is not a direct call (0x%02X) - lever disabled",
                   (unsigned long long)FireNormaliseCallRva(), s_callsite[0]);
        return AbandonCallsitePatch();
    }
    int32_t rel = 0;
    std::memcpy(&rel, s_callsite + 1, 4);
    if (reinterpret_cast<uintptr_t>(s_callsite + 5 + rel) != normalise) {
        LogWarning("[AimGetter] C: +0x%llX does not call Normalize - lever disabled",
                   (unsigned long long)FireNormaliseCallRva());
        return AbandonCallsitePatch();
    }

    s_relay = AllocRelayNear(s_callsite);
    if (!s_relay) {
        LogError("[AimGetter] C: no relay page within reach of the call site");
        return AbandonCallsitePatch();
    }
    // mov rax, &Hook_FireNormalise ; jmp rax
    uint8_t stub[12] = { 0x48, 0xB8, 0,0,0,0,0,0,0,0, 0xFF, 0xE0 };
    const uint64_t dst = reinterpret_cast<uint64_t>(&Hook_FireNormalise);
    std::memcpy(stub + 2, &dst, 8);
    std::memcpy(s_relay, stub, sizeof(stub));
    FlushInstructionCache(GetCurrentProcess(), s_relay, sizeof(stub));

    const intptr_t delta = s_relay - (s_callsite + 5);
    if (delta < INT32_MIN || delta > INT32_MAX) {
        LogError("[AimGetter] C: relay out of rel32 range");
        return AbandonCallsitePatch();
    }
    std::memcpy(s_callsiteOrig, s_callsite, sizeof(s_callsiteOrig));

    uint8_t patch[5] = { 0xE8, 0, 0, 0, 0 };
    const int32_t rel32 = static_cast<int32_t>(delta);
    std::memcpy(patch + 1, &rel32, 4);

    DWORD oldProtect = 0;
    if (!VirtualProtect(s_callsite, sizeof(patch), PAGE_EXECUTE_READWRITE, &oldProtect)) {
        LogError("[AimGetter] C: VirtualProtect failed on the call site");
        return AbandonCallsitePatch();
    }
    std::memcpy(s_callsite, patch, sizeof(patch));
    FlushInstructionCache(GetCurrentProcess(), s_callsite, sizeof(patch));
    DWORD ignored = 0;
    VirtualProtect(s_callsite, sizeof(patch), oldProtect, &ignored);
    LogInfo("[AimGetter] C: call site +0x%llX routed through the head peel",
            (unsigned long long)FireNormaliseCallRva());
    return true;
}

}  // namespace

bool AimGetterHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (s_started.load(std::memory_order_acquire)) return true;
    if (!sdk) return false;

    // Every lever here is a code detour at a hardcoded address. On a build we
    // have not derived those against they belong to some other function, so all
    // three stay out rather than being bounds-checked into a false sense of
    // safety - ResolveCodeRva cannot tell a moved function from a matching one.
    if (!builds::HasActiveProfile()) {
        LogInfo("[AimGetter] no matching build profile - levers not installed");
        return false;
    }

    // Each lever is bounds-checked against the running image independently, so
    // a profile that carries only some of the RVAs still gets those.
    s_targetA = reinterpret_cast<void*>(
        modguard::ResolveCodeRva(GetWorldOrientationRva(), 16, "AimGetter A"));
    if (s_targetA &&
        !sdk->hooking->Attach(handle, s_targetA, reinterpret_cast<void*>(&Hook_GetWorldOrientation),
                              reinterpret_cast<void**>(&s_origA))) {
        LogError("[AimGetter] A: attach failed at +0x%llX", (unsigned long long)GetWorldOrientationRva());
        s_targetA = nullptr;
    }

    s_targetB = reinterpret_cast<void*>(
        modguard::ResolveCodeRva(GetWorldTransformRva(), 16, "AimGetter B"));
    if (s_targetB &&
        !sdk->hooking->Attach(handle, s_targetB, reinterpret_cast<void*>(&Hook_GetWorldTransform),
                              reinterpret_cast<void**>(&s_origB))) {
        LogError("[AimGetter] B: attach failed at +0x%llX", (unsigned long long)GetWorldTransformRva());
        s_targetB = nullptr;
    }

    PatchFireNormaliseCallsite();
    s_started.store(true, std::memory_order_release);
    LogInfo("[AimGetter] started (A=%d B=%d C=%d)",
            s_targetA ? 1 : 0, s_targetB ? 1 : 0, s_callsite ? 1 : 0);
    return true;
}

void AimGetterHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (!s_started.exchange(false, std::memory_order_acq_rel)) return;

    if (s_callsite && s_callsiteOrig[0] == 0xE8) {
        DWORD oldProtect = 0;
        if (VirtualProtect(s_callsite, sizeof(s_callsiteOrig), PAGE_EXECUTE_READWRITE, &oldProtect)) {
            std::memcpy(s_callsite, s_callsiteOrig, sizeof(s_callsiteOrig));
            FlushInstructionCache(GetCurrentProcess(), s_callsite, sizeof(s_callsiteOrig));
            DWORD ignored = 0;
            VirtualProtect(s_callsite, sizeof(s_callsiteOrig), oldProtect, &ignored);
        }
    }
    s_callsite = nullptr;
    if (s_relay) {
        VirtualFree(s_relay, 0, MEM_RELEASE);
        s_relay = nullptr;
    }

    if (sdk) {
        if (s_targetA) sdk->hooking->Detach(handle, s_targetA);
        if (s_targetB) sdk->hooking->Detach(handle, s_targetB);
    }
    s_targetA = nullptr;
    s_targetB = nullptr;
    s_origA = nullptr;
    s_origB = nullptr;
    LogInfo("[AimGetter] stopped");
}

void AimGetterHook_Tick() {
    HeadTrackingState* w = g_sharedState.GetWritable();
    if (w) {
        s_mode.store(w->aim_getter_mode, std::memory_order_relaxed);
        w->aim_getter_calls_a = s_callsA.load(std::memory_order_relaxed);
        w->aim_getter_calls_b = s_callsB.load(std::memory_order_relaxed);
        w->aim_getter_calls_c = s_callsC.load(std::memory_order_relaxed);
        w->aim_getter_overrides = s_overrides.load(std::memory_order_relaxed);
    }

    // One 30s wall-clock window drives both the heartbeat and the caller
    // census, and each writes a line only when its own picture changed. A
    // shipped build that is not firing therefore sits silent instead of
    // writing four lines every five seconds for the life of the session.
    const uint64_t now = GetTickCount64();
    if (s_lastWindowMs != 0 && now - s_lastWindowMs < 30000) return;
    const uint64_t elapsed = s_lastWindowMs ? (now - s_lastWindowMs) : 30000;
    s_lastWindowMs = now;

    const CallerCensus censusA = DrainCallers(s_callersA);
    const CallerCensus censusB = DrainCallers(s_callersB);
    if (!SameCallers(censusA, s_lastCensusA)) {
        LogCallers("A", censusA);
        s_lastCensusA = censusA;
    }
    if (!SameCallers(censusB, s_lastCensusB)) {
        LogCallers("B", censusB);
        s_lastCensusB = censusB;
    }

    const uint32_t a = s_callsA.load(std::memory_order_relaxed);
    const uint32_t b = s_callsB.load(std::memory_order_relaxed);
    const uint32_t c = s_callsC.load(std::memory_order_relaxed);
    const uint32_t mode = s_mode.load(std::memory_order_relaxed);

    // A, B and C tick on every frame of ordinary gameplay, so comparing their
    // VALUES reported the same line every 30s for the whole session. Report the
    // mode and whether each lever is moving at all; the 5-minute liveness line
    // carries the running totals, which is where growth shows up.
    const bool moving[3] = {a != s_lastCallsA, b != s_lastCallsB, c != s_lastCallsC};
    const bool changed = mode != s_lastMode ||
                         moving[0] != s_lastMoving[0] ||
                         moving[1] != s_lastMoving[1] ||
                         moving[2] != s_lastMoving[2];
    // Counters are rebased every window whether or not a line goes out, so the
    // rates below always describe the window just closed rather than however
    // many silent windows preceded it.
    if (changed || now - s_lastLiveLogMs > 300000) {
        s_lastLiveLogMs = now;
        LogInfo("[AimGetter] heartbeat: mode=%u A=%u (%.1f/s match=%u) B=%u (%.1f/s match=%u) "
                "C=%u (%.1f/s match=%u) overrides=%u smartPeels=%u",
                mode,
                a, (a - s_lastCallsA) * 1000.0 / elapsed, s_matchA.load(std::memory_order_relaxed),
                b, (b - s_lastCallsB) * 1000.0 / elapsed, s_matchB.load(std::memory_order_relaxed),
                c, (c - s_lastCallsC) * 1000.0 / elapsed, s_matchC.load(std::memory_order_relaxed),
                s_overrides.load(std::memory_order_relaxed),
                s_smartGunPeels.load(std::memory_order_relaxed));
    }
    s_lastCallsA = a; s_lastCallsB = b; s_lastCallsC = c; s_lastMode = mode;
    s_lastMoving[0] = moving[0]; s_lastMoving[1] = moving[1]; s_lastMoving[2] = moving[2];
}


bool AimGetterHook_IsActive() {
    return s_started.load(std::memory_order_acquire);
}

bool AimGetterHook_CorrectPreviewDirection(float* direction) {
    if (!direction) return false;
    float head[4];
    float camWorld[4];
    if (!ReadHead(head) || !ReadCamWorld(camWorld)) return false;
    if (!PeelWorldDirection(direction, head, camWorld)) return false;
    return ApplyPositionToWorldDirection(direction, head, camWorld);
}
