// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo

#include "RicochetPreviewHook.hpp"

#include <Windows.h>

#include <atomic>
#include <cstdint>
#include <cstring>

#include "AimGetterHook.hpp"
#include "ModuleGuard.hpp"
#include "builds/build_registry.hpp"

void LogInfo(const char* fmt, ...);
void LogError(const char* fmt, ...);

namespace {

using EffectExecuteFn = uint64_t(__fastcall*)(void*, void*, float, void*, void*);
using PhysicalRayExecuteFn = uint64_t(__fastcall*)(void*, void*, void*);
using NormaliseFn = void*(__fastcall*)(float*, float*);

void* s_effectExecuteTarget = nullptr;
EffectExecuteFn s_effectExecuteOriginal = nullptr;
void* s_physicalRayExecuteTarget = nullptr;
PhysicalRayExecuteFn s_physicalRayExecuteOriginal = nullptr;
NormaliseFn s_normaliseOriginal = nullptr;
uint8_t* s_normaliseCallsite = nullptr;
uint8_t s_normaliseCallsiteOriginal[5]{};
uint8_t* s_normaliseRelay = nullptr;
thread_local uint32_t s_effectExecuteDepth = 0;
thread_local uint32_t s_ricochetRaysThisEffect = 0;
thread_local bool s_correctPhysicalRay = false;
thread_local bool s_inRicochetRay = false;

// One-shot capture of the first ricochet chain that has more than one segment.
// Segment 1's direction before and after the peel, plus segment 2's direction,
// is enough to work out which of the two the engine mirrored off the surface -
// the corrected one (the chain is consistent and any residual error is
// elsewhere) or the raw head-rotated one (the reflection reads a direction our
// Normalize rewrite never reaches, and the bounce needs correcting at the
// source instead).
std::atomic<bool> s_chainLogged{false};
thread_local float s_firstRayDirty[3]{};
thread_local float s_firstRayClean[3]{};
thread_local bool s_firstRayCaptured = false;

constexpr uint64_t kRicochetQueryPreset = 0x2F7CC7CC7D209D9Full;
constexpr uint64_t kRicochetFilterPreset = 0xD50F938BF00EA64Eull;

bool IsRicochetPhysicalRay(void* self) {
    bool matches = false;
    __try {
        const uint64_t queryPreset = *reinterpret_cast<const uint64_t*>(
            reinterpret_cast<const uint8_t*>(self) + 0xD8);
        const auto* filter = *reinterpret_cast<const uint8_t* const*>(
            reinterpret_cast<const uint8_t*>(self) + 0xC8);
        const uint64_t filterPreset = filter
            ? *reinterpret_cast<const uint64_t*>(filter + 0x50)
            : 0;
        matches = queryPreset == kRicochetQueryPreset &&
                  filterPreset == kRicochetFilterPreset;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        matches = false;
    }
    return matches;
}

uint64_t __fastcall EffectExecuteHook(void* self, void* context, float value,
                                      void* arg4, void* arg5) {
    if (s_effectExecuteDepth == 0) {
        s_ricochetRaysThisEffect = 0;
        s_firstRayCaptured = false;
    }
    ++s_effectExecuteDepth;
    const uint64_t result = s_effectExecuteOriginal(self, context, value, arg4,
                                                     arg5);
    --s_effectExecuteDepth;
    return result;
}

// The head rotation only ever sits on the FIRST ray of a ricochet chain - the
// one shot out of the tracked camera. Every later segment's direction is a
// reflection the engine derived from the previous segment and the surface it
// hit, so it is already expressed in clean world space. Peeling those too
// rotates each bounce by the head pose on top of the mirror, which is why a
// preview line that lands on a target still sends the round over its head.
uint64_t __fastcall PhysicalRayExecuteHook(void* self, void* context,
                                           void* input) {
    const bool previousCorrect = s_correctPhysicalRay;
    const bool previousRicochet = s_inRicochetRay;
    const bool ricochetRay = IsRicochetPhysicalRay(self) &&
                             s_effectExecuteDepth == 1;
    if (ricochetRay) ++s_ricochetRaysThisEffect;
    s_inRicochetRay = ricochetRay;
    s_correctPhysicalRay = ricochetRay && s_ricochetRaysThisEffect == 1;
    const uint64_t result = s_physicalRayExecuteOriginal(self, context, input);
    s_correctPhysicalRay = previousCorrect;
    s_inRicochetRay = previousRicochet;
    return result;
}

void* __fastcall RicochetNormaliseHook(float* input, float* output) {
    void* result = s_normaliseOriginal(input, output);
    // The call site is shared by every PhysicalRay executor, not just the
    // ricochet ones, so nothing below may run on a ray we did not classify.
    if (!output || !s_inRicochetRay) return result;

    const bool firstRicochetRay =
        s_ricochetRaysThisEffect == 1 && !s_firstRayCaptured;
    if (firstRicochetRay) {
        s_firstRayCaptured = true;
        for (int i = 0; i < 3; ++i) s_firstRayDirty[i] = output[i];
    }

    if (s_correctPhysicalRay) AimGetterHook_CorrectPreviewDirection(output);

    if (firstRicochetRay) {
        for (int i = 0; i < 3; ++i) s_firstRayClean[i] = output[i];
    } else if (s_ricochetRaysThisEffect == 2 && s_firstRayCaptured &&
               !s_chainLogged.exchange(true, std::memory_order_relaxed)) {
        LogInfo("[RicochetPreview] chain: seg1 dirty=(%+.4f,%+.4f,%+.4f) "
                "clean=(%+.4f,%+.4f,%+.4f) seg2=(%+.4f,%+.4f,%+.4f)",
                s_firstRayDirty[0], s_firstRayDirty[1], s_firstRayDirty[2],
                s_firstRayClean[0], s_firstRayClean[1], s_firstRayClean[2],
                output[0], output[1], output[2]);
    }
    return result;
}

uint8_t* AllocateRelayNear(uint8_t* target) {
    SYSTEM_INFO systemInfo{};
    GetSystemInfo(&systemInfo);
    const uintptr_t granularity = systemInfo.dwAllocationGranularity;
    const uintptr_t base = reinterpret_cast<uintptr_t>(target);
    for (uintptr_t distance = granularity; distance < 0x70000000ull;
         distance += granularity) {
        const uintptr_t candidates[2] = {
            base + distance,
            base > distance ? base - distance : 0,
        };
        for (uintptr_t candidate : candidates) {
            if (!candidate) continue;
            void* memory = VirtualAlloc(
                reinterpret_cast<void*>(candidate & ~(granularity - 1)),
                granularity, MEM_RESERVE | MEM_COMMIT,
                PAGE_EXECUTE_READWRITE);
            if (memory) return static_cast<uint8_t*>(memory);
        }
    }
    return nullptr;
}

void ClearNormaliseCallsite() {
    if (s_normaliseRelay) {
        VirtualFree(s_normaliseRelay, 0, MEM_RELEASE);
        s_normaliseRelay = nullptr;
    }
    s_normaliseCallsite = nullptr;
    s_normaliseOriginal = nullptr;
}

bool PatchNormaliseCallsite() {
    const auto& offsets = builds::ActiveProfile().Offsets;
    const uintptr_t normalise = modguard::ResolveCodeRva(
        offsets.NormaliseFn, 16, "PhysicalRay Normalize");
    const uintptr_t callsite = modguard::ResolveCodeRva(
        offsets.PhysicalRayNormaliseCall, 5,
        "PhysicalRay Normalize callsite");
    if (!normalise || !callsite) return false;

    s_normaliseOriginal = reinterpret_cast<NormaliseFn>(normalise);
    s_normaliseCallsite = reinterpret_cast<uint8_t*>(callsite);
    if (s_normaliseCallsite[0] != 0xE8) {
        LogError("[RicochetPreview] Normalize callsite is not a direct call");
        ClearNormaliseCallsite();
        return false;
    }

    int32_t originalRelative = 0;
    std::memcpy(&originalRelative, s_normaliseCallsite + 1, 4);
    if (reinterpret_cast<uintptr_t>(s_normaliseCallsite + 5 +
                                    originalRelative) != normalise) {
        LogError("[RicochetPreview] Normalize callsite target changed");
        ClearNormaliseCallsite();
        return false;
    }

    s_normaliseRelay = AllocateRelayNear(s_normaliseCallsite);
    if (!s_normaliseRelay) {
        LogError("[RicochetPreview] could not allocate a nearby relay");
        ClearNormaliseCallsite();
        return false;
    }

    uint8_t relay[12] = {0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xE0};
    const uint64_t destination = reinterpret_cast<uint64_t>(
        &RicochetNormaliseHook);
    std::memcpy(relay + 2, &destination, 8);
    std::memcpy(s_normaliseRelay, relay, sizeof(relay));
    FlushInstructionCache(GetCurrentProcess(), s_normaliseRelay,
                          sizeof(relay));

    const intptr_t delta = s_normaliseRelay - (s_normaliseCallsite + 5);
    if (delta < INT32_MIN || delta > INT32_MAX) {
        LogError("[RicochetPreview] Normalize relay is out of range");
        ClearNormaliseCallsite();
        return false;
    }

    std::memcpy(s_normaliseCallsiteOriginal, s_normaliseCallsite,
                sizeof(s_normaliseCallsiteOriginal));
    uint8_t patch[5] = {0xE8, 0, 0, 0, 0};
    const int32_t relative = static_cast<int32_t>(delta);
    std::memcpy(patch + 1, &relative, 4);
    DWORD oldProtect = 0;
    if (!VirtualProtect(s_normaliseCallsite, sizeof(patch),
                        PAGE_EXECUTE_READWRITE, &oldProtect)) {
        LogError("[RicochetPreview] could not unlock Normalize callsite");
        ClearNormaliseCallsite();
        return false;
    }
    std::memcpy(s_normaliseCallsite, patch, sizeof(patch));
    FlushInstructionCache(GetCurrentProcess(), s_normaliseCallsite,
                          sizeof(patch));
    DWORD ignored = 0;
    VirtualProtect(s_normaliseCallsite, sizeof(patch), oldProtect, &ignored);
    return true;
}

void RestoreNormaliseCallsite() {
    if (s_normaliseCallsite && s_normaliseCallsiteOriginal[0] == 0xE8) {
        DWORD oldProtect = 0;
        if (VirtualProtect(s_normaliseCallsite,
                           sizeof(s_normaliseCallsiteOriginal),
                           PAGE_EXECUTE_READWRITE, &oldProtect)) {
            std::memcpy(s_normaliseCallsite, s_normaliseCallsiteOriginal,
                        sizeof(s_normaliseCallsiteOriginal));
            FlushInstructionCache(GetCurrentProcess(), s_normaliseCallsite,
                                  sizeof(s_normaliseCallsiteOriginal));
            DWORD ignored = 0;
            VirtualProtect(s_normaliseCallsite,
                           sizeof(s_normaliseCallsiteOriginal), oldProtect,
                           &ignored);
        }
    }
    ClearNormaliseCallsite();
}

}  // namespace

bool RicochetPreviewHook_Start(const RED4ext::v1::Sdk* sdk,
                               RED4ext::v1::PluginHandle handle) {
    if (!sdk || !sdk->hooking || !builds::HasActiveProfile()) return false;

    const auto& offsets = builds::ActiveProfile().Offsets;
    s_effectExecuteTarget = reinterpret_cast<void*>(modguard::ResolveCodeRva(
        offsets.RicochetEffectExecute, 16, "Ricochet effect execution"));
    s_physicalRayExecuteTarget = reinterpret_cast<void*>(
        modguard::ResolveCodeRva(offsets.PhysicalRayExecute, 16,
                                "PhysicalRay execution"));
    if (!s_effectExecuteTarget || !s_physicalRayExecuteTarget) return false;

    if (!sdk->hooking->Attach(handle, s_effectExecuteTarget,
                              reinterpret_cast<void*>(&EffectExecuteHook),
                              reinterpret_cast<void**>(&s_effectExecuteOriginal))) {
        LogError("[RicochetPreview] could not attach effect execution hook");
        s_effectExecuteTarget = nullptr;
        return false;
    }
    if (!sdk->hooking->Attach(
            handle, s_physicalRayExecuteTarget,
            reinterpret_cast<void*>(&PhysicalRayExecuteHook),
            reinterpret_cast<void**>(&s_physicalRayExecuteOriginal))) {
        LogError("[RicochetPreview] could not attach PhysicalRay hook");
        sdk->hooking->Detach(handle, s_effectExecuteTarget);
        s_effectExecuteTarget = nullptr;
        s_effectExecuteOriginal = nullptr;
        s_physicalRayExecuteTarget = nullptr;
        return false;
    }
    if (!PatchNormaliseCallsite()) {
        sdk->hooking->Detach(handle, s_physicalRayExecuteTarget);
        sdk->hooking->Detach(handle, s_effectExecuteTarget);
        s_physicalRayExecuteTarget = nullptr;
        s_physicalRayExecuteOriginal = nullptr;
        s_effectExecuteTarget = nullptr;
        s_effectExecuteOriginal = nullptr;
        return false;
    }

    LogInfo("[RicochetPreview] initial-ray correction active");
    return true;
}

void RicochetPreviewHook_Stop(const RED4ext::v1::Sdk* sdk,
                              RED4ext::v1::PluginHandle handle) {
    RestoreNormaliseCallsite();
    if (s_physicalRayExecuteTarget) {
        sdk->hooking->Detach(handle, s_physicalRayExecuteTarget);
    }
    if (s_effectExecuteTarget) {
        sdk->hooking->Detach(handle, s_effectExecuteTarget);
    }
    s_physicalRayExecuteTarget = nullptr;
    s_physicalRayExecuteOriginal = nullptr;
    s_effectExecuteTarget = nullptr;
    s_effectExecuteOriginal = nullptr;
}
