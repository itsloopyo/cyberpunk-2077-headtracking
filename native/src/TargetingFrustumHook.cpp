// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "TargetingFrustumHook.hpp"

#include <Windows.h>
#include <intrin.h>

#include <atomic>
#include <cmath>
#include <cstdint>

#include "ModuleGuard.hpp"
#include "NativeRunningHook.hpp"
#include "QuatMath.hpp"
#include "ScriptChannel.hpp"
#include "builds/build_registry.hpp"

void LogInfo(const char* fmt, ...);
void LogError(const char* fmt, ...);

namespace {

// Layout of the per-player targeting record the update writes, read off the
// update itself (+0x4B9D84) and checked against the camera in game.
//
// The update copies all of these from the FPP camera, and it runs after the
// CET half has composed the head rotation into that camera, so every one of
// them follows the head. (From Lua the same camera reads clean: the engine
// resets it to the mouse orientation before CET's update runs.)
constexpr size_t kViewPosition    = 0x31100;  // Vector4
constexpr size_t kViewPositionCopy = 0x31120; // Vector4, the same eye
constexpr size_t kCrosshairOrigin = 0x311F0;  // Vector4, the same eye
constexpr size_t kViewOrientation = 0x31110;  // Quaternion (i, j, k, r)
constexpr size_t kFrustumPlanes   = 0x31130;  // 6 x (normal xyz, d)
constexpr int    kPlaneCount      = 6;
constexpr size_t kCrosshairFwd    = 0x31200;  // Vector4
constexpr size_t kCrosshairAngles = 0x31210;  // roll, pitch, yaw in degrees:
                                              // what each object's angular
                                              // distance from the crosshair is
                                              // measured against
// In the UI job's ray (the struct at the query's second argument), the
// direction follows the eye position.
constexpr size_t kRayDirection    = 0x14;
// In the camera transform the interface hands back, the orientation follows
// the position.
constexpr size_t kTransformOrientation = 0x10;

// The record's crosshair is the camera forward, so the first frustum plane (the
// near plane) and the crosshair have to agree before this touches anything. A
// record where they do not is a state these offsets were not read from.
constexpr float kSameDirectionDot = 0.9999f;

using UpdateFn  = void*(__fastcall*)(void*, void*);
using AnglesFn  = float*(__fastcall*)(const float*, float*);
using RayFn     = void*(__fastcall*)(void*, void*, void*, void*, void*);
using CamXfFn   = void*(__fastcall*)(void*, void*, void*);

void*     s_updateTarget = nullptr;
UpdateFn  s_updateOrig   = nullptr;
void*     s_rayTarget    = nullptr;
RayFn     s_rayOrig      = nullptr;
AnglesFn  s_toAngles     = nullptr;
uintptr_t s_rayReturn    = 0;
void*     s_camXfTarget  = nullptr;
CamXfFn   s_camXfOrig    = nullptr;
uintptr_t s_camXfReturn  = 0;

// The last correction, for the UI job's ray to reuse. Written by the update on
// the job thread, read by the UI job on another, so it is published under a
// sequence counter and a reader that sees the counter move retries once.
struct Snapshot {
    float rendered[3];
    float clean[3];
    float angles[3];
    // The camera's share of the lean, in world space. The targeting casts from
    // the eye the round leaves from: at the hip the lean rides the camera
    // alone, so that is the eye without it. The rig's share moves the eye and
    // the round together and is not in here.
    float lean[3];
};
Snapshot                s_snap{};
std::atomic<uint32_t>   s_snapSeq{0};
std::atomic<uint64_t>   s_snapMs{0};

std::atomic<uint32_t> s_calls{0};
std::atomic<uint32_t> s_turned{0};
std::atomic<uint32_t> s_mismatch{0};
std::atomic<uint32_t> s_faults{0};
std::atomic<uint32_t> s_rays{0};
std::atomic<uint32_t> s_raycasts{0};
std::atomic<uint32_t> s_logged{0};
std::atomic<uint64_t> s_lastBeatMs{0};

void Rotate(const float q[4], const float v[3], float out[3]) {
    // v' = q * v * conj(q)
    float tx, ty, tz, tw;
    quatmath::QuatMul(q[0], q[1], q[2], q[3], v[0], v[1], v[2], 0.0f, tx, ty, tz, tw);
    float ox, oy, oz, ow;
    quatmath::QuatMul(tx, ty, tz, tw, -q[0], -q[1], -q[2], q[3], ox, oy, oz, ow);
    out[0] = ox; out[1] = oy; out[2] = oz;
}

float Dot3(const float* a, const float* b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }

bool HeadActive(float h[4]) {
    h[0] = g_headQuat[0]; h[1] = g_headQuat[1]; h[2] = g_headQuat[2]; h[3] = g_headQuat[3];
    const float lenSq = h[0]*h[0] + h[1]*h[1] + h[2]*h[2] + h[3]*h[3];
    const float delta = std::fabs(h[0]) + std::fabs(h[1]) + std::fabs(h[2]) +
                        std::fabs(1.0f - std::fabs(h[3]));
    return std::isfinite(lenSq) && lenSq > 0.5f && lenSq < 1.5f && delta >= 1e-4f;
}

enum class TurnResult { Skipped, Turned, Mismatch, Fault };

struct TurnTrace {
    float yawBefore;
    float yawAfter;
};

// POD-only: runs under SEH.
TurnResult TurnRecord(uint8_t* rec, TurnTrace& t) {
    float h[4];
    if (!HeadActive(h)) return TurnResult::Skipped;

    __try {
        float* pos = reinterpret_cast<float*>(rec + kViewPosition);
        float* posCopy = reinterpret_cast<float*>(rec + kViewPositionCopy);
        float* origin = reinterpret_cast<float*>(rec + kCrosshairOrigin);
        float* q   = reinterpret_cast<float*>(rec + kViewOrientation);
        float* pl  = reinterpret_cast<float*>(rec + kFrustumPlanes);
        float* fwd = reinterpret_cast<float*>(rec + kCrosshairFwd);
        float* ang = reinterpret_cast<float*>(rec + kCrosshairAngles);

        const float qLenSq = q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3];
        if (!std::isfinite(qLenSq) || qLenSq < 0.9f || qLenSq > 1.1f) return TurnResult::Skipped;
        if (!(Dot3(pl, fwd) > kSameDirectionDot)) return TurnResult::Mismatch;

        // The head rotation is composed on the right of the camera orientation
        // (camera.lua: local = clean * head), so the clean view is q * conj(h),
        // and the world-space turn that takes the rendered view back onto it is
        // clean * conj(q).
        float c[4];
        quatmath::QuatMul(q[0], q[1], q[2], q[3], -h[0], -h[1], -h[2], h[3], c[0], c[1], c[2], c[3]);
        const float cLen = std::sqrt(c[0]*c[0] + c[1]*c[1] + c[2]*c[2] + c[3]*c[3]);
        if (!std::isfinite(cLen) || cLen < 0.1f) return TurnResult::Skipped;
        for (float& v : c) v /= cLen;
        float r[4];
        quatmath::QuatMul(c[0], c[1], c[2], c[3], -q[0], -q[1], -q[2], q[3], r[0], r[1], r[2], r[3]);

        float cleanFwd[4] = { 0.0f, 0.0f, 0.0f, fwd[3] };
        Rotate(r, fwd, cleanFwd);

        // g_headPos is the camera's share of the lean in its parent's frame
        // (camera.lua pos_local), and the parent carries the clean view.
        const float headPos[3] = { g_headPos[0], g_headPos[1], g_headPos[2] };
        float lean[3] = { 0.0f, 0.0f, 0.0f };
        if (std::isfinite(headPos[0] + headPos[1] + headPos[2])) Rotate(c, headPos, lean);
        const float eye[3] = { pos[0] - lean[0], pos[1] - lean[1], pos[2] - lean[2] };
        float scratch[4] = {};
        const float* a = s_toAngles(cleanFwd, scratch);
        if (!a || !std::isfinite(a[0]) || !std::isfinite(a[1]) || !std::isfinite(a[2])) {
            return TurnResult::Skipped;
        }

        const uint32_t seq = s_snapSeq.load(std::memory_order_relaxed);
        s_snapSeq.store(seq + 1, std::memory_order_release);
        for (int k = 0; k < 3; ++k) {
            s_snap.rendered[k] = fwd[k];
            s_snap.clean[k]    = cleanFwd[k];
            s_snap.angles[k]   = a[k];
            s_snap.lean[k]     = lean[k];
        }
        s_snapSeq.store(seq + 2, std::memory_order_release);

        t.yawBefore = ang[2];
        t.yawAfter  = a[2];

        for (int i = 0; i < kPlaneCount; ++i) {
            float* n = pl + i * 4;
            float turned[3];
            Rotate(r, n, turned);
            // Keep each plane's offset along its normal (the near and far
            // distances) and move only the part that passes through the eye.
            n[3] += (n[0] * pos[0] + n[1] * pos[1] + n[2] * pos[2]) -
                    (turned[0] * eye[0] + turned[1] * eye[1] + turned[2] * eye[2]);
            n[0] = turned[0]; n[1] = turned[1]; n[2] = turned[2];
        }
        fwd[0] = cleanFwd[0]; fwd[1] = cleanFwd[1]; fwd[2] = cleanFwd[2];
        for (int k = 0; k < 3; ++k) {
            pos[k] = eye[k];
            posCopy[k] = eye[k];
            origin[k] = eye[k];
        }
        ang[0] = a[0]; ang[1] = a[1]; ang[2] = a[2];
        q[0] = c[0]; q[1] = c[1]; q[2] = c[2]; q[3] = c[3];
        return TurnResult::Turned;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return TurnResult::Fault;
    }
}

void Heartbeat() {
    const uint64_t now = GetTickCount64();
    uint64_t last = s_lastBeatMs.load(std::memory_order_relaxed);
    if (now - last < 30000) return;
    if (!s_lastBeatMs.compare_exchange_strong(last, now, std::memory_order_relaxed)) return;
    LogInfo("[TargetingFrustum] heartbeat: updates=%u turned=%u mismatch=%u faults=%u uiRays=%u crosshairRaycasts=%u",
            s_calls.load(std::memory_order_relaxed), s_turned.load(std::memory_order_relaxed),
            s_mismatch.load(std::memory_order_relaxed), s_faults.load(std::memory_order_relaxed),
            s_rays.load(std::memory_order_relaxed), s_raycasts.load(std::memory_order_relaxed));
}

void* __fastcall Hook_Update(void* rec, void* camera) {
    void* ret = s_updateOrig(rec, camera);
    s_calls.fetch_add(1, std::memory_order_relaxed);

    // The vehicle chase camera carries its head rotation by another route
    // (ChaseCameraHook), so the right-multiplied peel does not describe it.
    if (rec && !ScriptChannel_ChaseCameraActive()) {
        TurnTrace t{};
        switch (TurnRecord(static_cast<uint8_t*>(rec), t)) {
        case TurnResult::Turned:
            s_turned.fetch_add(1, std::memory_order_relaxed);
            s_snapMs.store(GetTickCount64(), std::memory_order_relaxed);
            if (s_logged.fetch_add(1, std::memory_order_relaxed) < 3) {
                LogInfo("[TargetingFrustum] crosshair turned onto the aim: yaw %.2f -> %.2f",
                        t.yawBefore, t.yawAfter);
            }
            break;
        case TurnResult::Mismatch:
            if (s_mismatch.fetch_add(1, std::memory_order_relaxed) < 3) {
                LogInfo("[TargetingFrustum] record crosshair is not the camera forward - left as rendered");
            }
            break;
        case TurnResult::Fault:
            if (s_faults.fetch_add(1, std::memory_order_relaxed) == 0) {
                LogError("[TargetingFrustum] access fault in the targeting record at %p", rec);
            }
            break;
        case TurnResult::Skipped:
            break;
        }
    }
    Heartbeat();
    return ret;
}

// POD-only: runs under SEH.
bool CorrectUiRay(uint8_t* ray, float* angles) {
    if (GetTickCount64() - s_snapMs.load(std::memory_order_relaxed) > 250) return false;
    Snapshot snap;
    for (int attempt = 0; attempt < 2; ++attempt) {
        const uint32_t before = s_snapSeq.load(std::memory_order_acquire);
        if (before & 1u) continue;
        snap = s_snap;
        if (s_snapSeq.load(std::memory_order_acquire) == before) {
            __try {
                float* dir = reinterpret_cast<float*>(ray + kRayDirection);
                // Only a ray cast along the view the record was turned from.
                if (!(Dot3(dir, snap.rendered) > kSameDirectionDot)) return false;
                dir[0] = snap.clean[0]; dir[1] = snap.clean[1]; dir[2] = snap.clean[2];
                float* from = reinterpret_cast<float*>(ray);
                from[0] -= snap.lean[0]; from[1] -= snap.lean[1]; from[2] -= snap.lean[2];
                angles[0] = snap.angles[0]; angles[1] = snap.angles[1]; angles[2] = snap.angles[2];
                return true;
            } __except (EXCEPTION_EXECUTE_HANDLER) {
                return false;
            }
        }
    }
    return false;
}

void* __fastcall Hook_UiRay(void* self, void* ray, void* angles, void* a4, void* a5) {
    const uintptr_t ra = reinterpret_cast<uintptr_t>(_ReturnAddress());
    if (ra == s_rayReturn && ray && angles && !ScriptChannel_ChaseCameraActive()) {
        if (CorrectUiRay(static_cast<uint8_t*>(ray), static_cast<float*>(angles))) {
            s_rays.fetch_add(1, std::memory_order_relaxed);
        }
    }
    return s_rayOrig(self, ray, angles, a4, a5);
}

// POD-only: runs under SEH.
bool CleanCameraTransform(uint8_t* xf) {
    if (GetTickCount64() - s_snapMs.load(std::memory_order_relaxed) > 250) return false;
    float h[4];
    if (!HeadActive(h)) return false;
    float rendered[3], lean[3];
    const uint32_t before = s_snapSeq.load(std::memory_order_acquire);
    if (before & 1u) return false;
    for (int k = 0; k < 3; ++k) { rendered[k] = s_snap.rendered[k]; lean[k] = s_snap.lean[k]; }
    if (s_snapSeq.load(std::memory_order_acquire) != before) return false;
    __try {
        float* q = reinterpret_cast<float*>(xf + kTransformOrientation);
        const float qLenSq = q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3];
        if (!std::isfinite(qLenSq) || qLenSq < 0.9f || qLenSq > 1.1f) return false;
        // Only the camera the record was turned from: its forward (+Y) has to
        // be the rendered view forward.
        const float fwdLocal[3] = { 0.0f, 1.0f, 0.0f };
        float f[3];
        Rotate(q, fwdLocal, f);
        if (!(Dot3(f, rendered) > kSameDirectionDot)) return false;
        float c[4];
        quatmath::QuatMul(q[0], q[1], q[2], q[3], -h[0], -h[1], -h[2], h[3], c[0], c[1], c[2], c[3]);
        const float cLen = std::sqrt(c[0]*c[0] + c[1]*c[1] + c[2]*c[2] + c[3]*c[3]);
        if (!std::isfinite(cLen) || cLen < 0.1f) return false;
        q[0] = c[0] / cLen; q[1] = c[1] / cLen; q[2] = c[2] / cLen; q[3] = c[3] / cLen;
        float* p = reinterpret_cast<float*>(xf);
        p[0] -= lean[0]; p[1] -= lean[1]; p[2] -= lean[2];
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

void* __fastcall Hook_CameraTransform(void* self, void* out, void* owner) {
    void* ret = s_camXfOrig(self, out, owner);
    const uintptr_t ra = reinterpret_cast<uintptr_t>(_ReturnAddress());
    if (ra == s_camXfReturn && out && !ScriptChannel_ChaseCameraActive()) {
        if (CleanCameraTransform(static_cast<uint8_t*>(out))) {
            s_raycasts.fetch_add(1, std::memory_order_relaxed);
        }
    }
    return ret;
}

}  // namespace

bool TargetingFrustumHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (!sdk || !builds::HasActiveProfile()) {
        LogInfo("[TargetingFrustum] no matching build profile - not installed");
        return false;
    }
    const auto& o = builds::ActiveProfile().Offsets;
    s_toAngles = reinterpret_cast<AnglesFn>(modguard::ResolveCodeRva(o.DirectionToAngles, 16, "TargetingFrustum angles"));
    s_updateTarget = reinterpret_cast<void*>(modguard::ResolveCodeRva(o.TargetingRecordUpdate, 16, "TargetingFrustum update"));
    s_rayTarget = reinterpret_cast<void*>(modguard::ResolveCodeRva(o.UiTargetRayQuery, 16, "TargetingFrustum ui ray"));
    const uintptr_t base = modguard::ExeBase();
    s_rayReturn = (base && o.UiTargetRayQueryReturn) ? base + o.UiTargetRayQueryReturn : 0;
    if (!s_toAngles || !s_updateTarget) return false;

    if (!sdk->hooking->Attach(handle, s_updateTarget, reinterpret_cast<void*>(&Hook_Update),
                              reinterpret_cast<void**>(&s_updateOrig))) {
        LogError("[TargetingFrustum] attach failed at +0x%llX", (unsigned long long)o.TargetingRecordUpdate);
        s_updateTarget = nullptr;
        return false;
    }
    s_camXfTarget = reinterpret_cast<void*>(modguard::ResolveCodeRva(o.CameraTransformFn, 16, "TargetingFrustum camera transform"));
    s_camXfReturn = (base && o.CrosshairRaycastCameraReturn) ? base + o.CrosshairRaycastCameraReturn : 0;
    if (s_camXfTarget && s_camXfReturn &&
        !sdk->hooking->Attach(handle, s_camXfTarget, reinterpret_cast<void*>(&Hook_CameraTransform),
                              reinterpret_cast<void**>(&s_camXfOrig))) {
        LogError("[TargetingFrustum] camera transform attach failed at +0x%llX", (unsigned long long)o.CameraTransformFn);
        s_camXfTarget = nullptr;
    }
    if (s_rayTarget && s_rayReturn &&
        !sdk->hooking->Attach(handle, s_rayTarget, reinterpret_cast<void*>(&Hook_UiRay),
                              reinterpret_cast<void**>(&s_rayOrig))) {
        LogError("[TargetingFrustum] ui ray attach failed at +0x%llX", (unsigned long long)o.UiTargetRayQuery);
        s_rayTarget = nullptr;
    }
    LogInfo("[TargetingFrustum] installed (update +0x%llX, ui ray %s, crosshair raycast %s)",
            (unsigned long long)o.TargetingRecordUpdate, s_rayTarget ? "on" : "off", s_camXfTarget ? "on" : "off");
    return true;
}

void TargetingFrustumHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (sdk && s_camXfTarget) sdk->hooking->Detach(handle, s_camXfTarget);
    s_camXfTarget = nullptr;
    s_camXfOrig = nullptr;
    if (sdk && s_rayTarget) sdk->hooking->Detach(handle, s_rayTarget);
    if (sdk && s_updateTarget) sdk->hooking->Detach(handle, s_updateTarget);
    s_rayTarget = nullptr;
    s_rayOrig = nullptr;
    s_updateTarget = nullptr;
    s_updateOrig = nullptr;
}
