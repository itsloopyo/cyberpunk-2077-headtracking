// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo

#include "PositionProviderHook.hpp"

#include <RED4ext/RED4ext.hpp>

#include <Windows.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "NativeRunningHook.hpp"
#include "QuatMath.hpp"
#include "SharedState.hpp"

extern SharedState g_sharedState;

void LogInfo(const char* fmt, ...);
void LogWarning(const char* fmt, ...);
void LogError(const char* fmt, ...);

namespace {

constexpr int kClassCount = 1;
const char* const kClassNames[kClassCount] = {
    "entFuncPositionProvider",
};

constexpr int kSlotLo = 3;
constexpr int kSlotCount = 48;
constexpr int kPositionSlot = 33;
constexpr int kPositionIndex = kPositionSlot - kSlotLo;
constexpr int kThunkCount = kClassCount * kSlotCount;
constexpr int kThunkSize = 16;
constexpr int kWorldPositionDelta = 0x10;
constexpr int kWorldOrientationDelta = 0x20;
constexpr float kCameraMatchDistanceSq = 16.0f;

struct ThunkPage {
    uint64_t counters[kThunkCount];
    uint64_t origs[kThunkCount];
    uint8_t code[kThunkCount * kThunkSize];
};

ThunkPage* s_page = nullptr;
std::atomic<bool> s_installed{false};
uintptr_t s_vtables[kClassCount] = {};
void* s_positionOrig[kClassCount] = {};
std::atomic<uint32_t> s_calls{0};
std::atomic<uint32_t> s_overrides{0};
uint64_t s_lastHeartbeatMs = 0;
uint32_t s_logged = 0;

struct PositionTrace {
    float out[3];
    float camera[3];
    float distanceSq;
    int reason;
};

void EmitThunk(uint8_t* code, uint64_t* counter, uint64_t* orig) {
    uint8_t* p = code;
    *p++ = 0x48; *p++ = 0xFF; *p++ = 0x05;
    int32_t rel = static_cast<int32_t>(reinterpret_cast<uint8_t*>(counter) - (p + 4));
    std::memcpy(p, &rel, 4); p += 4;
    *p++ = 0xFF; *p++ = 0x25;
    rel = static_cast<int32_t>(reinterpret_cast<uint8_t*>(orig) - (p + 4));
    std::memcpy(p, &rel, 4);
}

bool CorrectPosition(uintptr_t outp, PositionTrace& trace) {
    trace = {};
    const HeadTrackingState state = g_sharedState.Read();
    if (!state.enabled || state.provider_mode == 0) {
        trace.reason = 1;
        return false;
    }

    const float px = state.position_x;
    const float py = state.position_y;
    const float pz = state.position_z;
    const bool positionActive =
        std::fabs(px) + std::fabs(py) + std::fabs(pz) > 0.00001f;

    const float hx = g_headQuat[0];
    const float hy = g_headQuat[1];
    const float hz = g_headQuat[2];
    const float hw = g_headQuat[3];
    const float hLenSq = hx*hx + hy*hy + hz*hz + hw*hw;
    if (!std::isfinite(hLenSq) || hLenSq < 0.5f || hLenSq > 1.5f) {
        trace.reason = 3;
        return false;
    }

    void* cam = g_camInstance;
    const int camOff = g_camOrientationOffset;
    if (!cam || camOff < 0) {
        trace.reason = 4;
        return false;
    }

    __try {
        float* out = reinterpret_cast<float*>(outp);
        const float ox = out[0];
        const float oy = out[1];
        const float oz = out[2];
        trace.out[0] = ox; trace.out[1] = oy; trace.out[2] = oz;
        if (!std::isfinite(ox) || !std::isfinite(oy) || !std::isfinite(oz)) {
            trace.reason = 5;
            return false;
        }

        const auto* base = reinterpret_cast<const uint8_t*>(cam) + camOff;
        const float* cameraPosition = reinterpret_cast<const float*>(base + kWorldPositionDelta);
        const float dx = ox - cameraPosition[0];
        const float dy = oy - cameraPosition[1];
        const float dz = oz - cameraPosition[2];
        trace.camera[0] = cameraPosition[0];
        trace.camera[1] = cameraPosition[1];
        trace.camera[2] = cameraPosition[2];
        trace.distanceSq = dx*dx + dy*dy + dz*dz;
        if (!std::isfinite(dx) || !std::isfinite(dy) || !std::isfinite(dz) ||
            trace.distanceSq > kCameraMatchDistanceSq) {
            trace.reason = 6;
            return false;
        }
        if (!positionActive) {
            trace.reason = 2;
            return false;
        }

        const float* cameraOrientation =
            reinterpret_cast<const float*>(base + kWorldOrientationDelta);
        float qx, qy, qz, qw;
        quatmath::QuatMul(
            cameraOrientation[0], cameraOrientation[1], cameraOrientation[2],
            cameraOrientation[3], -hx, -hy, -hz, hw, qx, qy, qz, qw);
        const float qLenSq = qx*qx + qy*qy + qz*qz + qw*qw;
        if (!std::isfinite(qLenSq) || qLenSq < 0.5f || qLenSq > 1.5f) {
            trace.reason = 7;
            return false;
        }
        const float qInvLen = 1.0f / std::sqrt(qLenSq);
        qx *= qInvLen; qy *= qInvLen; qz *= qInvLen; qw *= qInvLen;

        const float cx = qy * pz - qz * py;
        const float cy = qz * px - qx * pz;
        const float cz = qx * py - qy * px;
        const float worldX = px + 2.0f * (qw * cx + qy * cz - qz * cy);
        const float worldY = py + 2.0f * (qw * cy + qz * cx - qx * cz);
        const float worldZ = pz + 2.0f * (qw * cz + qx * cy - qy * cx);

        out[0] = ox - worldX;
        out[1] = oy - worldY;
        out[2] = oz - worldZ;
        s_overrides.fetch_add(1, std::memory_order_relaxed);
        trace.reason = 0;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        trace.reason = 8;
        return false;
    }
}

template <int C>
uintptr_t __fastcall PositionStub(uintptr_t rcx, uintptr_t rdx, uintptr_t r8, uintptr_t r9) {
    using Fn = uintptr_t(__fastcall*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t);
    Fn orig = reinterpret_cast<Fn>(s_positionOrig[C]);
    const uintptr_t ret = orig ? orig(rcx, rdx, r8, r9) : 0;
    s_calls.fetch_add(1, std::memory_order_relaxed);
    const uintptr_t outp = rdx ? rdx : ret;
    PositionTrace trace{};
    if (outp) CorrectPosition(outp, trace);
    if (s_logged < 12 && trace.reason != 1) {
        ++s_logged;
        LogInfo("[PositionProvider] cls=%s out=(%+.3f,%+.3f,%+.3f) cam=(%+.3f,%+.3f,%+.3f) distSq=%.3f reason=%d",
                kClassNames[C], trace.out[0], trace.out[1], trace.out[2],
                trace.camera[0], trace.camera[1], trace.camera[2],
                trace.distanceSq, trace.reason);
    }
    return ret;
}

void* PositionStubFor(int c) {
    return c == 0 ? reinterpret_cast<void*>(&PositionStub<0>) : nullptr;
}

bool InstallClass(RED4ext::CRTTISystem* rtti, int c) {
    RED4ext::CClass* cls = rtti->GetClass(RED4ext::CName(kClassNames[c]));
    if (!cls) {
        LogWarning("[PositionProvider] class %s not found in RTTI", kClassNames[c]);
        return false;
    }
    void* inst = cls->CreateInstance(true);
    if (!inst) {
        LogWarning("[PositionProvider] CreateInstance failed for %s", kClassNames[c]);
        return false;
    }

    uintptr_t vt = 0;
    __try {
        vt = *reinterpret_cast<uintptr_t*>(inst);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        vt = 0;
    }
    if (!vt) return false;

    for (int i = 0; i < c; ++i) {
        if (s_vtables[i] == vt) {
            s_vtables[c] = vt;
            return true;
        }
    }

    uintptr_t* slot0 = reinterpret_cast<uintptr_t*>(vt + kSlotLo * sizeof(void*));
    DWORD oldProtect = 0;
    if (!VirtualProtect(slot0, kSlotCount * sizeof(void*), PAGE_EXECUTE_READWRITE, &oldProtect)) {
        LogError("[PositionProvider] VirtualProtect failed for %s vtable", kClassNames[c]);
        return false;
    }

    for (int i = 0; i < kSlotCount; ++i) {
        const int idx = c * kSlotCount + i;
        uintptr_t* slot = reinterpret_cast<uintptr_t*>(vt + (kSlotLo + i) * sizeof(void*));
        s_page->origs[idx] = *slot;
        if (i == kPositionIndex) {
            s_positionOrig[c] = reinterpret_cast<void*>(*slot);
            *slot = reinterpret_cast<uintptr_t>(PositionStubFor(c));
        } else {
            *slot = reinterpret_cast<uintptr_t>(s_page->code + idx * kThunkSize);
        }
    }

    DWORD ignored = 0;
    VirtualProtect(slot0, kSlotCount * sizeof(void*), oldProtect, &ignored);
    s_vtables[c] = vt;
    LogInfo("[PositionProvider] instrumented %s vtable=%p, position slot %d",
            kClassNames[c], reinterpret_cast<void*>(vt), kPositionSlot);
    return true;
}

bool Install() {
    auto* rtti = RED4ext::CRTTISystem::Get();
    if (!rtti || !rtti->GetClass(RED4ext::CName(kClassNames[kClassCount - 1]))) return false;

    s_page = static_cast<ThunkPage*>(VirtualAlloc(
        nullptr, sizeof(ThunkPage), MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE));
    if (!s_page) return false;
    std::memset(s_page, 0, sizeof(ThunkPage));
    for (int i = 0; i < kThunkCount; ++i) {
        EmitThunk(s_page->code + i * kThunkSize, &s_page->counters[i], &s_page->origs[i]);
    }
    FlushInstructionCache(GetCurrentProcess(), s_page->code, sizeof(s_page->code));

    int installed = 0;
    for (int c = 0; c < kClassCount; ++c) {
        if (InstallClass(rtti, c)) ++installed;
    }
    if (installed == 0) {
        VirtualFree(s_page, 0, MEM_RELEASE);
        s_page = nullptr;
        return false;
    }
    LogInfo("[PositionProvider] installed on %d/%d provider classes", installed, kClassCount);
    return true;
}

void Heartbeat() {
    const uint64_t now = GetTickCount64();
    if (s_lastHeartbeatMs != 0 && now - s_lastHeartbeatMs < 5000) return;
    s_lastHeartbeatMs = now;

    int topSlot = -1;
    uint64_t topCount = 0;
    for (int i = 0; i < kThunkCount; ++i) {
        if (s_page->counters[i] > topCount) {
            topCount = s_page->counters[i];
            topSlot = i % kSlotCount + kSlotLo;
        }
    }
    LogInfo("[PositionProvider] heartbeat: calls=%u overrides=%u busiestSlot=%d:%llu",
            s_calls.load(std::memory_order_relaxed),
            s_overrides.load(std::memory_order_relaxed), topSlot,
            static_cast<unsigned long long>(topCount));
}

}  // namespace

bool PositionProviderHook_Tick() {
    if (!s_installed.load(std::memory_order_acquire)) {
        if (!Install()) return false;
        s_installed.store(true, std::memory_order_release);
    }
    Heartbeat();
    return true;
}

void PositionProviderHook_Stop() {
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
    }

    VirtualFree(s_page, 0, MEM_RELEASE);
    s_page = nullptr;
    LogInfo("[PositionProvider] vtables restored");
}
