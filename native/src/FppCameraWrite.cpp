// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "FppCameraWrite.hpp"

#include <Windows.h>
#include <atomic>
#include <cmath>
#include <cstdint>

#include "NativeRunningHook.hpp"
#include "ScriptChannel.hpp"

#include <RED4ext/RTTISystem.hpp>
#include <RED4ext/Scripting/Functions.hpp>
#include <RED4ext/Scripting/Stack.hpp>

void LogInfo(const char* fmt, ...);

// Re-stamps the FPP camera's orientation from native, once per frame, after the
// script tick.
//
// WHAT THIS IS NOT: it is not the fix for the Shift (Nexus 22340) conflict. It
// was written as one and measured not to be. Both mods write the same slot -
// SetLocalOrientation on the component GetFPPCameraComponent() returns, which
// holds one absolute quaternion - and CET runs mod update handlers in
// folder-name order, so "Shift" lands after "HeadTracking" and wins. Adding
// this tick did not restore head tracking with Shift configured, which is the
// only thing that would have shown it lands late enough. What actually fixed
// that conflict is modules/shift_compat.lua, which asks Shift through its own
// published API to stand its camera sources down.
//
// WHAT IT IS: a defence for the window between our Lua write and this tick. A
// write that lands in that window is undone on the frames this tick runs, which
// is not all of them: it stands down without a fresh push from Lua, in the
// chase camera, and with no resolved camera instance. It does nothing at all
// about a writer that runs after this tick.
//
// Lua still owns the composition; this only repeats its most recent result. So
// it is safe whichever way the two tick orders resolve:
//
//   native after Lua  - a no-op when nothing clobbered us, corrective when
//                       something did.
//   native before Lua - writes the previous frame's value moments before Lua
//                       writes the current one, and Lua wins as it always did.
//
// Nothing on this side can separate "another mod wrote after Lua" from "the
// engine's own camera update ran between Lua and us", so neither the heartbeat
// nor the one-shot line may name a culprit, and neither is evidence for which
// of the two orderings above is in effect.

namespace {

// Latest orientation Lua asked us to hold, and a sequence counter so the tick
// can tell whether the script half has run since it last looked. Single
// writer (the script thread), single reader (the OnUpdate tick).
float                 s_quat[4] = {0, 0, 0, 1};
std::atomic<uint32_t> s_seq{0};
std::atomic<bool>     s_active{false};

uint32_t s_seqAtLastTick = 0;
bool     s_haveTicked = false;

std::atomic<uint32_t> s_stamps{0};
std::atomic<uint32_t> s_intact{0};

bool s_conflictLogged = false;

uint64_t s_lastLogMs = 0;
uint32_t s_loggedStamps = 0;
uint32_t s_loggedIntact = 0;

// A quaternion that is neither finite nor roughly unit length has no business
// reaching the camera. Same bound the other hooks use.
inline bool IsValidUnitish(float x, float y, float z, float w) {
    const float lenSq = x * x + y * y + z * z + w * w;
    return std::isfinite(lenSq) && lenSq > 0.5f && lenSq < 1.5f;
}

// Loose enough to absorb the float round-trip through the RTTI call and the
// engine's own storage, tight enough that a real camera-mod offset (degrees,
// not millidegrees) always trips it.
constexpr float kSameQuatEps = 1e-4f;

inline bool SameQuat(const float* a, const float* b) {
    return std::fabs(a[0] - b[0]) < kSameQuatEps &&
           std::fabs(a[1] - b[1]) < kSameQuatEps &&
           std::fabs(a[2] - b[2]) < kSameQuatEps &&
           std::fabs(a[3] - b[3]) < kSameQuatEps;
}

// SEH-wrapped access to the camera's orientation field. Separate functions
// because MSVC (C2712) forbids __try in a frame holding C++ objects with
// destructors, and because the pointer comes from an RTTI walk that can go
// stale across a load screen.
bool SehReadQuat(const void* src, float* out) {
    __try {
        const float* p = reinterpret_cast<const float*>(src);
        out[0] = p[0];
        out[1] = p[1];
        out[2] = p[2];
        out[3] = p[3];
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool SehWriteQuat(void* dst, const float* in) {
    __try {
        float* p = reinterpret_cast<float*>(dst);
        p[0] = in[0];
        p[1] = in[1];
        p[2] = in[2];
        p[3] = in[3];
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// Game.HeadTrackingSetFppOrientation(qi, qj, qk, qr, active) -> Bool
//
// Called from camera.lua on the same line it writes SetLocalOrientation, so
// what we hold is always exactly what Lua last put in the slot. `active`
// false stands the stamp down (tracking suppressed, chase camera, rotation
// switched off) and is pushed on those frames too - going quiet would leave
// us re-stamping a pose the player no longer has.
void SetFppOrientation(RED4ext::IScriptable*, RED4ext::CStackFrame* aFrame,
                       bool* aOut, int64_t) {
    float qi = 0.0f, qj = 0.0f, qk = 0.0f, qr = 1.0f;
    bool active = false;
    RED4ext::GetParameter(aFrame, &qi);
    RED4ext::GetParameter(aFrame, &qj);
    RED4ext::GetParameter(aFrame, &qk);
    RED4ext::GetParameter(aFrame, &qr);
    RED4ext::GetParameter(aFrame, &active);
    ++aFrame->code;

    if (!active) {
        s_active.store(false, std::memory_order_relaxed);
        s_seq.fetch_add(1, std::memory_order_release);
        if (aOut) *aOut = true;
        return;
    }

    // Script values cross a trust boundary and this one is written straight
    // into the camera, so reject rather than clamp.
    if (!IsValidUnitish(qi, qj, qk, qr)) {
        s_active.store(false, std::memory_order_relaxed);
        if (aOut) *aOut = false;
        return;
    }

    s_quat[0] = qi;
    s_quat[1] = qj;
    s_quat[2] = qk;
    s_quat[3] = qr;
    s_active.store(true, std::memory_order_relaxed);
    s_seq.fetch_add(1, std::memory_order_release);
    if (aOut) *aOut = true;
}

}  // namespace

void FppCameraWrite_Register(RED4ext::CRTTISystem* rtti) {
    if (!rtti) return;
    auto* fn = RED4ext::CGlobalFunction::Create(
        "HeadTrackingSetFppOrientation", "HeadTrackingSetFppOrientation",
        &SetFppOrientation);
    fn->flags.isNative = true;
    fn->AddParam("Float", "qi");
    fn->AddParam("Float", "qj");
    fn->AddParam("Float", "qk");
    fn->AddParam("Float", "qr");
    fn->AddParam("Bool", "active");
    fn->SetReturnType("Bool");
    rtti->RegisterFunction(fn);
}

void FppCameraWrite_Tick() {
    const uint32_t seq = s_seq.load(std::memory_order_acquire);
    const bool luaRefreshed = s_haveTicked && seq != s_seqAtLastTick;
    s_seqAtLastTick = seq;
    s_haveTicked = true;

    // Only ever re-stamp a value the script half has refreshed since the last
    // tick. Head tracking stops publishing whenever it stops writing - no
    // fresh tracker sample, camera component gone - and stamping a held pose
    // over the engine's own camera update every frame would pin the view and
    // take mouse look with it.
    if (!luaRefreshed) return;
    if (!s_active.load(std::memory_order_relaxed)) return;

    // The vehicle chase camera renders from its own component and ignores this
    // slot entirely; ChaseCameraHook owns the head rotation there.
    if (ScriptChannel_ChaseCameraActive()) return;

    void* cam = g_camInstance;
    const int off = g_camOrientationOffset;
    if (!cam || off < 0) return;
    void* slot = reinterpret_cast<uint8_t*>(cam) + off;

    float quat[4] = {s_quat[0], s_quat[1], s_quat[2], s_quat[3]};
    if (!IsValidUnitish(quat[0], quat[1], quat[2], quat[3])) return;

    float current[4];
    if (!SehReadQuat(slot, current)) return;

    if (SameQuat(current, quat)) {
        s_intact.fetch_add(1, std::memory_order_relaxed);
    } else if (!s_conflictLogged) {
        s_conflictLogged = true;
        LogInfo("[FppCameraWrite] the FPP camera orientation is not what the CET half last "
                "wrote, so something writes it between the two. That is either another "
                "camera mod or the engine's own camera update; this side cannot tell them "
                "apart. Head tracking is re-stamped over it each frame either way.");
    }

    if (!SehWriteQuat(slot, quat)) return;
    s_stamps.fetch_add(1, std::memory_order_relaxed);

    // Rate is what matters, so gate on divergence SINCE THE LAST LINE rather
    // than on the cumulative totals: comparing those would let one divergence
    // early in a session pin this to the 30-second cadence for the rest of it.
    // A quiet install gets the five-minute liveness line and nothing else.
    const uint64_t now = GetTickCount64();
    const uint32_t stamps = s_stamps.load(std::memory_order_relaxed);
    const uint32_t intact = s_intact.load(std::memory_order_relaxed);
    if (s_lastLogMs == 0) {
        s_lastLogMs = now;
        s_loggedStamps = stamps;
        s_loggedIntact = intact;
    } else {
        const uint32_t dStamps = stamps - s_loggedStamps;
        const uint32_t dIntact = intact - s_loggedIntact;
        if ((dIntact != dStamps && now - s_lastLogMs > 30000) ||
            now - s_lastLogMs > 300000) {
            LogInfo("[FppCameraWrite] heartbeat: stamps=%u intact=%u "
                    "(+%u stamped, +%u intact since last line)",
                    stamps, intact, dStamps, dIntact);
            s_lastLogMs = now;
            s_loggedStamps = stamps;
            s_loggedIntact = intact;
        }
    }
}
