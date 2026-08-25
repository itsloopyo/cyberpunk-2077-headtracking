// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "ChaseCameraHook.hpp"

#include <Windows.h>
#include <atomic>
#include <cmath>
#include <cstdint>

#include "ModuleGuard.hpp"
#include "NativeRunningHook.hpp"  // g_headQuat, g_headPos
#include "QuatMath.hpp"
#include "ScriptChannel.hpp"
#include "builds/build_registry.hpp"

void LogInfo(const char* fmt, ...);
void LogError(const char* fmt, ...);

namespace {

// The publish takes the camera in RCX. Its pose builder reads the pose from
// this+0x4C0 - fixed-point world position at +0x00, orientation quaternion at
// +0x10 - which is where every copy the engine hands out is made FROM.
constexpr ptrdiff_t kPoseOffset = 0x4C0;
constexpr ptrdiff_t kQuatOffset = kPoseOffset + 0x10;

// REDengine's WorldPosition: three int32 fixed-point axes, 1/131072 of a metre
// each, which is what carries Night City's coordinates without losing precision
// at the far end of the map.
constexpr float kFixedPointPerMetre = 131072.0f;

// Below this the pose is close enough to neutral that composing it would only
// add noise, and seeding the remembered clean base off it would be worse than
// not injecting at all.
constexpr float kNeutralPose = 0.005f;

using PublishFn = void (*)(void*);

void* s_target = nullptr;
PublishFn s_original = nullptr;
std::atomic<bool> s_hooked{false};
std::atomic<uint32_t> s_calls{0};
std::atomic<uint32_t> s_injected{0};
std::atomic<uint32_t> s_faults{0};

// The SDK handles are kept so the detour can go in LATER, the first time the
// chase camera is actually active, rather than at plugin load. A detour into
// the camera publish is not something to have sitting in every session of a
// feature that ships switched off.
const RED4ext::v1::Sdk* s_sdk = nullptr;
RED4ext::v1::PluginHandle s_handle = nullptr;

// What we last wrote, and the engine's own value it was composed from. The
// engine rebuilds the pose most frames, but when it leaves ours in place the
// clean value cannot be read off the object any more - so keep the pair and
// recover it rather than composing head rotation onto head rotation.
struct Memory {
    float cleanQuat[4] = {0, 0, 0, 1};
    float writtenQuat[4] = {0, 0, 0, 0};
    int32_t cleanPos[3] = {0, 0, 0};
    int32_t writtenPos[3] = {0, 0, 0};
    bool quatValid = false;
    bool posValid = false;
};
Memory s_mem;

float s_worldOrientation[4] = {0, 0, 0, 1};
std::atomic<bool> s_worldOrientationValid{false};

bool IsUnitish(const float* q) {
    const float lenSq = q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3];
    return std::isfinite(lenSq) && lenSq > 0.5f && lenSq < 1.5f;
}

bool SameQuat(const float* a, const float* b) {
    constexpr float kEpsilon = 1e-6f;
    return std::fabs(a[0] - b[0]) <= kEpsilon && std::fabs(a[1] - b[1]) <= kEpsilon &&
           std::fabs(a[2] - b[2]) <= kEpsilon && std::fabs(a[3] - b[3]) <= kEpsilon;
}

// POD-only body: the caller wraps it in SEH, so nothing here may need
// unwinding. Returns the clean orientation through `cleanOut` for the
// translation, which has to be rotated by the pose the body is in rather than
// the one the head is in.
bool RotatePose(uint8_t* pose, const float* head, float* cleanOut) {
    float* q = reinterpret_cast<float*>(pose + 0x10);
    if (!IsUnitish(q)) return false;

    float clean[4];
    if (s_mem.quatValid && SameQuat(q, s_mem.writtenQuat)) {
        clean[0] = s_mem.cleanQuat[0]; clean[1] = s_mem.cleanQuat[1];
        clean[2] = s_mem.cleanQuat[2]; clean[3] = s_mem.cleanQuat[3];
    } else {
        clean[0] = q[0]; clean[1] = q[1]; clean[2] = q[2]; clean[3] = q[3];
    }

    // Head rotation is camera-local, so it composes on the right - the same
    // side and the same quaternion Lua right-multiplies into
    // cam.localOrientation on the first-person path.
    float nx, ny, nz, nw;
    quatmath::QuatMul(clean[0], clean[1], clean[2], clean[3],
                      head[0], head[1], head[2], head[3], nx, ny, nz, nw);
    const float lenSq = nx*nx + ny*ny + nz*nz + nw*nw;
    if (!std::isfinite(lenSq) || lenSq <= 0.01f) return false;
    const float invLen = 1.0f / std::sqrt(lenSq);

    for (int i = 0; i < 4; ++i) s_mem.cleanQuat[i] = clean[i];
    s_mem.writtenQuat[0] = nx * invLen; s_mem.writtenQuat[1] = ny * invLen;
    s_mem.writtenQuat[2] = nz * invLen; s_mem.writtenQuat[3] = nw * invLen;
    for (int i = 0; i < 4; ++i) q[i] = s_mem.writtenQuat[i];
    s_mem.quatValid = true;

    for (int i = 0; i < 4; ++i) cleanOut[i] = clean[i];
    return true;
}

// Offsets the camera's world position by the head translation, rotated out of
// camera-local space by the CLEAN orientation - so leaning follows the car's
// heading rather than wherever the head happens to be pointing.
void TranslatePose(uint8_t* pose, const float* clean) {
    const float lx = g_headPos[0], ly = g_headPos[1], lz = g_headPos[2];
    if (!std::isfinite(lx) || !std::isfinite(ly) || !std::isfinite(lz)) return;
    if (std::fabs(lx) + std::fabs(ly) + std::fabs(lz) <= 0.0005f) {
        s_mem.posValid = false;
        return;
    }

    const float qx = clean[0], qy = clean[1], qz = clean[2], qw = clean[3];
    const float tx = 2.0f * (qy * lz - qz * ly);
    const float ty = 2.0f * (qz * lx - qx * lz);
    const float tz = 2.0f * (qx * ly - qy * lx);
    const float world[3] = {lx + qw * tx + (qy * tz - qz * ty),
                            ly + qw * ty + (qz * tx - qx * tz),
                            lz + qw * tz + (qx * ty - qy * tx)};

    int32_t* axis = reinterpret_cast<int32_t*>(pose);
    int32_t clean_pos[3];
    if (s_mem.posValid && axis[0] == s_mem.writtenPos[0] && axis[1] == s_mem.writtenPos[1] &&
        axis[2] == s_mem.writtenPos[2]) {
        clean_pos[0] = s_mem.cleanPos[0];
        clean_pos[1] = s_mem.cleanPos[1];
        clean_pos[2] = s_mem.cleanPos[2];
    } else {
        clean_pos[0] = axis[0]; clean_pos[1] = axis[1]; clean_pos[2] = axis[2];
    }

    for (int i = 0; i < 3; ++i) {
        s_mem.cleanPos[i] = clean_pos[i];
        s_mem.writtenPos[i] = clean_pos[i] + static_cast<int32_t>(world[i] * kFixedPointPerMetre);
        axis[i] = s_mem.writtenPos[i];
    }
    s_mem.posValid = true;
}

void Hook_CameraPublish(void* self) {
    const uint32_t calls = s_calls.fetch_add(1, std::memory_order_relaxed) + 1;

    if (self && ScriptChannel_ChaseCameraActive()) {
        const float head[4] = {g_headQuat[0], g_headQuat[1], g_headQuat[2], g_headQuat[3]};
        const float delta = std::fabs(head[0]) + std::fabs(head[1]) + std::fabs(head[2]) +
                            std::fabs(1.0f - std::fabs(head[3]));
        if (IsUnitish(head) && delta > kNeutralPose) {
            __try {
                uint8_t* pose = reinterpret_cast<uint8_t*>(self) + kPoseOffset;
                float clean[4];
                if (RotatePose(pose, head, clean)) {
                    TranslatePose(pose, clean);
                    s_injected.fetch_add(1, std::memory_order_relaxed);
                }
            } __except (EXCEPTION_EXECUTE_HANDLER) {
                s_faults.fetch_add(1, std::memory_order_relaxed);
                s_mem.quatValid = false;
                s_mem.posValid = false;
            }
        }
    }

    if (self) {
        __try {
            const float* q = reinterpret_cast<const float*>(
                reinterpret_cast<uint8_t*>(self) + kQuatOffset);
            if (IsUnitish(q)) {
                s_worldOrientation[0] = q[0]; s_worldOrientation[1] = q[1];
                s_worldOrientation[2] = q[2]; s_worldOrientation[3] = q[3];
                s_worldOrientationValid.store(true, std::memory_order_release);
            }
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            s_worldOrientationValid.store(false, std::memory_order_release);
        }
    }

    if (s_original) {
        s_original(self);
    }

    if ((calls % 20000) == 0) {
        LogInfo("[ChaseCam] publish: calls=%u injected=%u faults=%u", calls,
                s_injected.load(std::memory_order_relaxed),
                s_faults.load(std::memory_order_relaxed));
    }
}

}  // namespace

bool ChaseCameraHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    // Records the handles only. Nothing is detoured until the chase camera is
    // actually active - see the note on s_sdk.
    s_sdk = sdk;
    s_handle = handle;
    return true;
}

void ChaseCameraHook_EnsureInstalled() {
    if (s_hooked.load(std::memory_order_acquire) || !s_sdk) return;

    if (!builds::HasActiveProfile()) {
        LogInfo("[ChaseCam] no matching build profile - the camera publish is not hooked");
        s_hooked.store(true, std::memory_order_release);
        return;
    }

    const uintptr_t rva = builds::ActiveProfile().Offsets.CameraPublishFn;
    if (rva == 0) return;

    const uintptr_t target = modguard::ResolveCodeRva(rva, 16, "CameraPublishFn");
    if (!target) return;

    void* addr = reinterpret_cast<void*>(target);
    if (!s_sdk->hooking->Attach(s_handle, addr, reinterpret_cast<void*>(&Hook_CameraPublish),
                                reinterpret_cast<void**>(&s_original))) {
        LogError("[ChaseCam] attach failed for the camera publish at +0x%llX",
                 static_cast<unsigned long long>(rva));
        s_original = nullptr;
        return;
    }

    s_target = addr;
    s_hooked.store(true, std::memory_order_release);
    LogInfo("[ChaseCam] camera publish hooked at +0x%llX",
            static_cast<unsigned long long>(rva));
}

void ChaseCameraHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (!s_hooked.exchange(false, std::memory_order_acq_rel)) return;
    if (sdk && s_target) {
        sdk->hooking->Detach(handle, s_target);
    }
    s_target = nullptr;
    s_original = nullptr;
    s_worldOrientationValid.store(false, std::memory_order_release);
    LogInfo("[ChaseCam] camera publish detached");
}

bool ChaseCameraHook_WorldOrientation(float* out) {
    if (!s_worldOrientationValid.load(std::memory_order_acquire)) return false;
    out[0] = s_worldOrientation[0]; out[1] = s_worldOrientation[1];
    out[2] = s_worldOrientation[2]; out[3] = s_worldOrientation[3];
    return true;
}
