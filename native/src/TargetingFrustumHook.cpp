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
// The update copies these from the FPP camera after the CET half has composed
// the head rotation into it, so they describe the rendered view. The record is
// only read here. Other systems read it as what the player can see, and writing
// the aim into any of it (crosshair, view or frustum) crashed the game a few
// seconds after a load.
constexpr size_t kViewOrientation = 0x31110;  // Quaternion (i, j, k, r)
constexpr size_t kFrustumPlanes   = 0x31130;  // 6 x (normal xyz, d)
constexpr size_t kCrosshairFwd    = 0x31200;  // Vector4
// In the camera transform the interface hands back, the orientation follows
// the position.
constexpr size_t kTransformOrientation = 0x10;

// The record's crosshair is the camera forward, so the first frustum plane (the
// near plane) and the crosshair have to agree before this reads anything more. A
// record where they do not is a state these offsets were not read from.
constexpr float kSameDirectionDot = 0.9999f;

using UpdateFn  = void*(__fastcall*)(void*, void*);
using CamXfFn   = void*(__fastcall*)(void*, void*, void*);

void*     s_updateTarget = nullptr;
UpdateFn  s_updateOrig   = nullptr;
void*     s_camXfTarget  = nullptr;
CamXfFn   s_camXfOrig    = nullptr;
uintptr_t s_camXfReturn  = 0;

// The rendered view the record last described, for the crosshair raycast to
// check its camera against. Written by the update on the job thread, read by the
// raycast on another, so it is published under a sequence counter.
struct Snapshot {
    float rendered[3];
    // The camera's share of the lean, in world space. The raycast casts from
    // the eye the round leaves from: at the hip the lean rides the camera
    // alone, so that is the eye without it. The rig's share moves the eye and
    // the round together and is not in here.
    float lean[3];
};
Snapshot                s_snap{};
std::atomic<uint32_t>   s_snapSeq{0};
std::atomic<uint64_t>   s_snapMs{0};

std::atomic<uint32_t> s_calls{0};
std::atomic<uint32_t> s_snapshots{0};
std::atomic<uint32_t> s_mismatch{0};
std::atomic<uint32_t> s_faults{0};
std::atomic<uint32_t> s_raycasts{0};
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

// The head rotation is composed on the right of the camera orientation
// (camera.lua: local = clean * head), so the clean view is q * conj(h).
bool CleanOf(const float q[4], const float h[4], float c[4]) {
    quatmath::QuatMul(q[0], q[1], q[2], q[3], -h[0], -h[1], -h[2], h[3], c[0], c[1], c[2], c[3]);
    const float len = std::sqrt(c[0]*c[0] + c[1]*c[1] + c[2]*c[2] + c[3]*c[3]);
    if (!std::isfinite(len) || len < 0.1f) return false;
    for (int k = 0; k < 4; ++k) c[k] /= len;
    return true;
}

enum class ReadResult { Skipped, Published, Mismatch, Fault };

// POD-only: runs under SEH.
ReadResult ReadRecord(const uint8_t* rec) {
    float h[4];
    if (!HeadActive(h)) return ReadResult::Skipped;

    __try {
        const float* q   = reinterpret_cast<const float*>(rec + kViewOrientation);
        const float* pl  = reinterpret_cast<const float*>(rec + kFrustumPlanes);
        const float* fwd = reinterpret_cast<const float*>(rec + kCrosshairFwd);

        const float qLenSq = q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3];
        if (!std::isfinite(qLenSq) || qLenSq < 0.9f || qLenSq > 1.1f) return ReadResult::Skipped;
        if (!(Dot3(pl, fwd) > kSameDirectionDot)) return ReadResult::Mismatch;

        float c[4];
        if (!CleanOf(q, h, c)) return ReadResult::Skipped;

        // g_headPos is the camera's share of the lean in its parent's frame
        // (camera.lua pos_local), and the parent carries the clean view.
        const float headPos[3] = { g_headPos[0], g_headPos[1], g_headPos[2] };
        float lean[3] = { 0.0f, 0.0f, 0.0f };
        if (std::isfinite(headPos[0] + headPos[1] + headPos[2])) Rotate(c, headPos, lean);

        const uint32_t seq = s_snapSeq.load(std::memory_order_relaxed);
        s_snapSeq.store(seq + 1, std::memory_order_release);
        for (int k = 0; k < 3; ++k) {
            s_snap.rendered[k] = fwd[k];
            s_snap.lean[k]     = lean[k];
        }
        s_snapSeq.store(seq + 2, std::memory_order_release);
        return ReadResult::Published;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return ReadResult::Fault;
    }
}

void Heartbeat() {
    const uint64_t now = GetTickCount64();
    uint64_t last = s_lastBeatMs.load(std::memory_order_relaxed);
    if (now - last < 30000) return;
    if (!s_lastBeatMs.compare_exchange_strong(last, now, std::memory_order_relaxed)) return;
    LogInfo("[TargetingFrustum] heartbeat: updates=%u snapshots=%u mismatch=%u faults=%u crosshairRaycasts=%u",
            s_calls.load(std::memory_order_relaxed), s_snapshots.load(std::memory_order_relaxed),
            s_mismatch.load(std::memory_order_relaxed), s_faults.load(std::memory_order_relaxed),
            s_raycasts.load(std::memory_order_relaxed));
}

void* __fastcall Hook_Update(void* rec, void* camera) {
    void* ret = s_updateOrig(rec, camera);
    s_calls.fetch_add(1, std::memory_order_relaxed);

    // The vehicle chase camera carries its head rotation by another route
    // (ChaseCameraHook), so the right-multiplied peel does not describe it.
    if (rec && !ScriptChannel_ChaseCameraActive()) {
        switch (ReadRecord(static_cast<const uint8_t*>(rec))) {
        case ReadResult::Published:
            s_snapshots.fetch_add(1, std::memory_order_relaxed);
            s_snapMs.store(GetTickCount64(), std::memory_order_relaxed);
            break;
        case ReadResult::Mismatch:
            if (s_mismatch.fetch_add(1, std::memory_order_relaxed) < 3) {
                LogInfo("[TargetingFrustum] record crosshair is not the camera forward - not read");
            }
            break;
        case ReadResult::Fault:
            if (s_faults.fetch_add(1, std::memory_order_relaxed) == 0) {
                LogError("[TargetingFrustum] access fault in the targeting record at %p", rec);
            }
            break;
        case ReadResult::Skipped:
            break;
        }
    }
    Heartbeat();
    return ret;
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
        // Only the rendered camera: its forward (+Y) has to be the view forward
        // the record last described.
        const float fwdLocal[3] = { 0.0f, 1.0f, 0.0f };
        float f[3];
        Rotate(q, fwdLocal, f);
        if (!(Dot3(f, rendered) > kSameDirectionDot)) return false;
        float c[4];
        if (!CleanOf(q, h, c)) return false;
        q[0] = c[0]; q[1] = c[1]; q[2] = c[2]; q[3] = c[3];
        float* p = reinterpret_cast<float*>(xf);
        p[0] -= lean[0]; p[1] -= lean[1]; p[2] -= lean[2];
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// Only with the sights up. Stock, the raycast only ever finds what is at the
// view centre, which is on screen; turned onto the aim at the hip it can pick an
// NPC the view is not showing, and the crowd system spawns and removes exactly
// those. At the hip it crashed the game a few seconds after a load (1 load in
// 24), in the crowd system's teardown. With the sights up the aim is the scope,
// which is on screen.
void* __fastcall Hook_CameraTransform(void* self, void* out, void* owner) {
    void* ret = s_camXfOrig(self, out, owner);
    const uintptr_t ra = reinterpret_cast<uintptr_t>(_ReturnAddress());
    if (ra == s_camXfReturn && out && ScriptChannel_LastPushIsAds() && !ScriptChannel_ChaseCameraActive()) {
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
    s_updateTarget = reinterpret_cast<void*>(modguard::ResolveCodeRva(o.TargetingRecordUpdate, 16, "TargetingFrustum update"));
    s_camXfTarget = reinterpret_cast<void*>(modguard::ResolveCodeRva(o.CameraTransformFn, 16, "TargetingFrustum camera transform"));
    const uintptr_t base = modguard::ExeBase();
    s_camXfReturn = (base && o.CrosshairRaycastCameraReturn) ? base + o.CrosshairRaycastCameraReturn : 0;
    // The raycast correction is the whole effect; the record only tells it which
    // camera is the rendered one. Neither is any use without the other.
    if (!s_updateTarget || !s_camXfTarget || !s_camXfReturn) return false;

    if (!sdk->hooking->Attach(handle, s_updateTarget, reinterpret_cast<void*>(&Hook_Update),
                              reinterpret_cast<void**>(&s_updateOrig))) {
        LogError("[TargetingFrustum] attach failed at +0x%llX", (unsigned long long)o.TargetingRecordUpdate);
        s_updateTarget = nullptr;
        return false;
    }
    if (!sdk->hooking->Attach(handle, s_camXfTarget, reinterpret_cast<void*>(&Hook_CameraTransform),
                              reinterpret_cast<void**>(&s_camXfOrig))) {
        LogError("[TargetingFrustum] camera transform attach failed at +0x%llX", (unsigned long long)o.CameraTransformFn);
        sdk->hooking->Detach(handle, s_updateTarget);
        s_updateTarget = nullptr;
        s_camXfTarget = nullptr;
        return false;
    }
    LogInfo("[TargetingFrustum] installed (record read at +0x%llX, crosshair raycast camera at +0x%llX)",
            (unsigned long long)o.TargetingRecordUpdate, (unsigned long long)o.CameraTransformFn);
    return true;
}

void TargetingFrustumHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (sdk && s_camXfTarget) sdk->hooking->Detach(handle, s_camXfTarget);
    s_camXfTarget = nullptr;
    s_camXfOrig = nullptr;
    if (sdk && s_updateTarget) sdk->hooking->Detach(handle, s_updateTarget);
    s_updateTarget = nullptr;
    s_updateOrig = nullptr;
}
