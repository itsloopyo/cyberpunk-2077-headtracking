#include "HitscanHook.hpp"
#include "AimCompensation.hpp"
#include "SharedState.hpp"
#include "NativeRunningHook.hpp"

// SetLocalOrientationHook was the click-edge tracker that fed shot-time
// camera-state remembrance. Hook removed in the snap/flash cleanup; the
// click-edge sequence is now permanently 0, which makes the "remembered shot
// vector" fast path a no-op (IsRememberedShotVectorMutation returns false,
// RememberShotVectorMutation early-exits). HitscanHook still runs without it.
static inline uint32_t SetLocalOrientationHook_GetClickEdgeSeq() { return 0; }

#include <windows.h>
#include <psapi.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <intrin.h>
#include <limits>

#pragma intrinsic(_ReturnAddress)

namespace {

constexpr uintptr_t kTargetHelperOffset = 0x46F774;
constexpr uintptr_t kTargetHelperShotReturnOffset = 0x46F017;
constexpr uintptr_t kNormalizeOffset = 0x13DE80;
constexpr uintptr_t kNormalizeCallsiteOffset = 0x46F0E5;
constexpr uintptr_t kNormalizeShotReturnOffset = 0x46F0EA;
constexpr uintptr_t kPhysicsCallsiteOffset = 0x46F1EA;
constexpr uintptr_t kTraceDispatchOffset = 0x1303EC;
constexpr uintptr_t kRayDispatchOffset = 0x14D80C;
constexpr uintptr_t kShotCandidateAOffset = 0x291D9C8;
constexpr uintptr_t kShotCandidateBOffset = 0x291DD54;
constexpr uintptr_t kShotInputClassifyOffset = 0x291FDE0;
constexpr uintptr_t kShotInputClassifyReturnProcessorOffset = 0x292279E;
constexpr uintptr_t kShotInputClassifyReturnAltProcessorOffset = 0x2923292;
constexpr uintptr_t kShotSourceSkipPredicateOffset = 0x1E4B60;
constexpr uintptr_t kShotQueueConsumerOffset = 0x291ED20;
constexpr uintptr_t kShotQueueBuildOffset = 0x291F968;
constexpr uintptr_t kShotCandidateWriterOffset = 0x2930410;
constexpr uintptr_t kShotCandidateLinkOffset = 0x291F58C;
constexpr uintptr_t kShotCandidateGateOffset = 0x291FEE0;
constexpr uintptr_t kShotVectorProcessorOffset = 0x292263C;
constexpr uintptr_t kShotVectorAltProcessorOffset = 0x292317C;
constexpr uintptr_t kShotFinalVectorWriteOffset = 0x29216D0;
constexpr bool kDisableNativeHitscanHook = true;
constexpr bool kUseNormalizeCallsitePatch = false;
constexpr bool kUseNormalizeHook = false;
constexpr bool kUseTargetHelperHook = false;
constexpr bool kUseTraceDispatchHook = false;
constexpr bool kUseRayDispatchProbe = false;
constexpr bool kUseShotOrchestratorProbe = false;
constexpr bool kUseShotQueueConsumerProbe = false;
constexpr bool kUseShotQueueBuildProbe = false;
constexpr bool kUseShotCandidateWriterHook = false;
constexpr bool kUseShotCandidateLinkHook = false;
constexpr bool kUseShotCandidateGateProbe = false;
constexpr bool kUseShotInputClassifyHook = false;
constexpr bool kUseShotVectorSourceHook = false;
constexpr bool kUseShotFinalVectorWriteHook = false;
constexpr bool kPublishNormalizeActive = true;
constexpr bool kPublishTargetHelperActive = true;
constexpr bool kPublishTraceDispatchActive = true;
constexpr bool kPublishShotOrchestratorActive = true;
constexpr bool kPublishShotQueueConsumerActive = false;
constexpr bool kPublishShotQueueBuildActive = false;
constexpr bool kPublishShotCandidateWriterActive = false;
constexpr bool kPublishShotCandidateLinkActive = false;
constexpr bool kPublishShotCandidateGateActive = false;
constexpr bool kPublishShotInputClassifyActive = true;
constexpr bool kPublishShotVectorSourceActive = false;
constexpr bool kPublishShotFinalVectorWriteActive = false;
constexpr bool kPublishPhysicsHookActive = true;
constexpr bool kTraceDispatchRequireShotWindow = true;
constexpr bool kMutateTraceDispatchRay = true;
constexpr bool kMutateShotOrchestratorSource = true;
constexpr bool kMutateShotInputClassifyTarget = true;
constexpr bool kMutateShotQueueConsumerSources = false;
constexpr bool kMutateShotCandidateWriterOutput = false;
constexpr bool kMutateShotVectorSource = false;
constexpr bool kMutateShotVectorAltSource = false;
constexpr bool kMutateShotVectorSourceAfterCall = false;
constexpr bool kRestoreShotVectorSourceAfterCall = false;
constexpr bool kMutateShotFinalVectorWrite = false;
constexpr bool kMutateNormalizeVector = false;
constexpr bool kRestoreSnapCleanAtNormalizeCallsite = false;
constexpr uint64_t kShotVectorWindowMs = 350;
constexpr uint32_t kShotVectorWindowMutateBudget = 128;
constexpr float kMaxShotCompensationDistance = 500.0f;
constexpr size_t kOriginalCallSize = 7;
constexpr size_t kNormalizeCallSize = 5;
constexpr size_t kCallPatchSize = 5;
constexpr size_t kRelaySize = 12;
constexpr bool kEnablePhysicsMutation = true;
constexpr bool kRestorePhysicsMutationAfterTrace = true;
constexpr uint32_t kSnapCleanProbeCallCount = 1;

constexpr uint8_t kExpectedCallBytes[kOriginalCallSize] = {
    0x41, 0xFF, 0x92, 0x50, 0x01, 0x00, 0x00
};

using PhysicsTraceFn = uintptr_t (*)(void* self, void* arg2, void* arg3, void* rayList);
using TraceDispatchFn = uintptr_t (*)(void* arg1, void* arg2, void* arg3, void* arg4, void* traceInput, void* arg6);
using RayDispatchFn = uintptr_t (*)(void* self, void* outResult, void* arg3, void* arg4);
using ShotCandidateFn = uintptr_t (*)(void* rcxArg, void* rdxArg, void* r8Arg, void* r9Arg);
using ShotQueueConsumerFn = void (*)(void* state, void* context, void* scratch, uint32_t arg4, uint32_t count, uint32_t arg6, uint32_t arg7);
using ShotQueueBuildFn = bool (*)(void* state, void* builder, void* context, void* weapon, uint64_t slotArg, uint64_t candidateIndexArg, void* candidateOut);
using ShotCandidateWriterFn = void (*)(void* source, void* context, void* weapon, uint8_t slot, int candidateIndex, uint32_t stateValue, int startIndex, void* out);
using ShotCandidateLinkFn = void (*)(void* state, void* candidateMeta, void* weaponData, uint16_t arg4, void* arg5);
using ShotCandidateGateFn = uint8_t (*)(void* state, void* candidateMeta, void* sourceData, void* weaponSlot, uint64_t weaponSlotPayload, void* candidateOut, void* vectorOut);
using ShotInputClassifyFn = uint32_t (*)(void* source, void* targetPoint);
using ShotSourceSkipPredicateFn = uint8_t (*)(void* sourceFlags);
using ShotVectorProcessorFn = void (*)(void* arg1, void* shotContext, void* shotList);
using ShotVectorAltProcessorFn = void (*)(void* arg1, void* shotContext, void* shotList, float arg4, uint32_t arg5);
using ShotFinalVectorWriteFn = void (*)(void* engineState, int index, uint32_t vectorCount, void* vector, void* payload);
using TargetHelperFn = uintptr_t (*)(void* arg1, void* outHit, void* shotContext, void* targetInfo, float* origin, float* target);
using NormalizeFn = void* (*)(float* input, float* output);

std::atomic<bool> s_hooked{false};
std::atomic<bool> s_publishActive{false};
uintptr_t s_exeBase = 0;
uint8_t* s_callsite = nullptr;
uint8_t* s_relay = nullptr;
uint8_t s_originalBytes[kOriginalCallSize]{};
uint8_t* s_normalizeCallsite = nullptr;
uint8_t* s_normalizeRelay = nullptr;
uint8_t s_originalNormalizeCallBytes[kNormalizeCallSize]{};
void* s_traceDispatchTarget = nullptr;
TraceDispatchFn s_originalTraceDispatch = nullptr;
void* s_rayDispatchTarget = nullptr;
RayDispatchFn s_originalRayDispatch = nullptr;
void* s_shotCandidateATarget = nullptr;
void* s_shotCandidateBTarget = nullptr;
ShotCandidateFn s_originalShotCandidateA = nullptr;
ShotCandidateFn s_originalShotCandidateB = nullptr;
void* s_shotQueueConsumerTarget = nullptr;
ShotQueueConsumerFn s_originalShotQueueConsumer = nullptr;
void* s_shotQueueBuildTarget = nullptr;
ShotQueueBuildFn s_originalShotQueueBuild = nullptr;
void* s_shotCandidateWriterTarget = nullptr;
ShotCandidateWriterFn s_originalShotCandidateWriter = nullptr;
void* s_shotCandidateLinkTarget = nullptr;
ShotCandidateLinkFn s_originalShotCandidateLink = nullptr;
void* s_shotCandidateGateTarget = nullptr;
ShotCandidateGateFn s_originalShotCandidateGate = nullptr;
void* s_shotInputClassifyTarget = nullptr;
ShotInputClassifyFn s_originalShotInputClassify = nullptr;
ShotSourceSkipPredicateFn s_shotSourceSkipPredicate = nullptr;
void* s_shotVectorProcessorTarget = nullptr;
void* s_shotVectorAltProcessorTarget = nullptr;
ShotVectorProcessorFn s_originalShotVectorProcessor = nullptr;
ShotVectorAltProcessorFn s_originalShotVectorAltProcessor = nullptr;
void* s_shotFinalVectorWriteTarget = nullptr;
ShotFinalVectorWriteFn s_originalShotFinalVectorWrite = nullptr;
void* s_targetHelperTarget = nullptr;
TargetHelperFn s_originalTargetHelper = nullptr;
void* s_normalizeTarget = nullptr;
NormalizeFn s_originalNormalize = nullptr;

std::atomic<uint32_t> s_fires{0};
std::atomic<uint32_t> s_candidateAFires{0};
std::atomic<uint32_t> s_candidateBFires{0};
std::atomic<uint32_t> s_targetHelperFires{0};
std::atomic<uint32_t> s_targetHelperMutated{0};
std::atomic<uint32_t> s_targetHelperSkipped{0};
std::atomic<uint32_t> s_targetHelperFaults{0};
std::atomic<uint32_t> s_normalizeFires{0};
std::atomic<uint32_t> s_normalizeMutated{0};
std::atomic<uint32_t> s_normalizeSkipped{0};
std::atomic<uint32_t> s_normalizeFaults{0};
std::atomic<uint32_t> s_traceDispatchCalls{0};
std::atomic<uint32_t> s_traceDispatchWindowCalls{0};
std::atomic<uint32_t> s_traceDispatchMutated{0};
std::atomic<uint32_t> s_traceDispatchSkipped{0};
std::atomic<uint32_t> s_traceDispatchFaults{0};
std::atomic<uint32_t> s_shotOrchestratorMutated{0};
std::atomic<uint32_t> s_shotOrchestratorSkipped{0};
std::atomic<uint32_t> s_shotOrchestratorFaults{0};
std::atomic<uint32_t> s_shotQueueConsumerCalls{0};
std::atomic<uint32_t> s_shotQueueConsumerMutated{0};
std::atomic<uint32_t> s_shotQueueConsumerSkipped{0};
std::atomic<uint32_t> s_shotQueueConsumerFaults{0};
std::atomic<uint32_t> s_shotQueueBuildCalls{0};
std::atomic<uint32_t> s_shotQueueBuildFaults{0};
std::atomic<uint32_t> s_shotCandidateWriterCalls{0};
std::atomic<uint32_t> s_shotCandidateWriterMutated{0};
std::atomic<uint32_t> s_shotCandidateWriterSkipped{0};
std::atomic<uint32_t> s_shotCandidateWriterFaults{0};
std::atomic<uint32_t> s_shotCandidateLinkCalls{0};
std::atomic<uint32_t> s_shotCandidateLinkFaults{0};
std::atomic<uint32_t> s_shotCandidateGateCalls{0};
std::atomic<uint32_t> s_shotCandidateGateFaults{0};
std::atomic<uint32_t> s_shotInputClassifyCalls{0};
std::atomic<uint32_t> s_shotInputClassifyMutated{0};
std::atomic<uint32_t> s_shotInputClassifySkipped{0};
std::atomic<uint32_t> s_shotInputClassifyFaults{0};
std::atomic<uint32_t> s_shotVectorProcessorCalls{0};
std::atomic<uint32_t> s_shotVectorAltProcessorCalls{0};
std::atomic<uint32_t> s_shotFinalVectorWriteCalls{0};
std::atomic<uint32_t> s_shotFinalVectorWriteMutated{0};
std::atomic<uint32_t> s_shotFinalVectorWriteSkipped{0};
std::atomic<uint32_t> s_shotFinalVectorWriteFaults{0};
std::atomic<uint32_t> s_shotVectorMutated{0};
std::atomic<uint32_t> s_shotVectorSkipped{0};
std::atomic<uint32_t> s_shotVectorFaults{0};
std::atomic<uint32_t> s_shotVectorNoPose{0};
std::atomic<uint32_t> s_shotVectorWindowShotSeq{0};
std::atomic<uint32_t> s_shotVectorWindowRestoreSeq{0};
std::atomic<uint32_t> s_shotVectorWindowClickSeq{0};
std::atomic<uint64_t> s_shotVectorWindowMs{0};
std::atomic<uint32_t> s_shotVectorWindowLogBudget{0};
std::atomic<uint32_t> s_shotVectorWindowMutateBudget{0};
std::atomic<bool> s_shotVectorWindowPrimed{false};
std::atomic<uint32_t> s_shotVectorPostRestoreSeq{0};
std::atomic<uint32_t> s_shotVectorPostRestores{0};
std::atomic<uint32_t> s_shotVectorPostRestoreSkipped{0};
std::atomic<uintptr_t> s_lastShotVectorSource{0};
std::atomic<int32_t> s_lastShotVectorNewX{0};
std::atomic<int32_t> s_lastShotVectorNewY{0};
std::atomic<int32_t> s_lastShotVectorNewZ{0};
std::atomic<uint32_t> s_lastShotVectorClickSeq{0};
std::atomic<uint32_t> s_compensated{0};
std::atomic<uint32_t> s_lookupFailed{0};
std::atomic<uint32_t> s_entriesSeen{0};
uint64_t s_lastHeartbeatMs = 0;

struct SavedVec3 {
    float* ptr;
    float x;
    float y;
    float z;
};

constexpr int kMaxSavedVecs = 128;

struct Vec3 {
    float x;
    float y;
    float z;
};

struct ShotVectorProbe {
    void* holder;
    void* entries;
    void* source;
    uint32_t count;
    uint32_t index;
    uint32_t kind;
    uint32_t reason;
    Vec3 value;
    Vec3 origin;
    float distance;
};

struct Vec4 {
    float x;
    float y;
    float z;
    float w;
};

struct SavedFixedVec3 {
    int32_t* ptr;
    int32_t x;
    int32_t y;
    int32_t z;
};

bool IsUnitish(float x, float y, float z) {
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) return false;
    const float mag2 = x * x + y * y + z * z;
    return mag2 >= 0.64f && mag2 <= 1.44f;
}

void RotateAndSave(float* v, float yaw, float pitch, SavedVec3* saved, int& savedCount) {
    const float x = v[0];
    const float y = v[1];
    const float z = v[2];
    if (!IsUnitish(x, y, z) || savedCount >= kMaxSavedVecs) return;

    saved[savedCount] = { v, x, y, z };
    ++savedCount;

    float rx = x;
    float ry = y;
    float rz = z;
    RotateVector(rx, ry, rz, yaw, pitch);
    v[0] = rx;
    v[1] = ry;
    v[2] = rz;
}

void RotateAndSaveDisplacement(float* v, float yaw, float pitch, SavedVec3* saved, int& savedCount) {
    const float x = v[0];
    const float y = v[1];
    const float z = v[2];
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) return;
    const float mag2 = x * x + y * y + z * z;
    if (mag2 < 0.0001f || mag2 > 1000000.0f || savedCount >= kMaxSavedVecs) return;

    saved[savedCount] = { v, x, y, z };
    ++savedCount;

    float rx = x;
    float ry = y;
    float rz = z;
    RotateVector(rx, ry, rz, yaw, pitch);
    v[0] = rx;
    v[1] = ry;
    v[2] = rz;
}

bool SaveAndWrite(float* v, const Vec3& value, SavedVec3* saved, int& savedCount) {
    if (!v || !saved || savedCount >= kMaxSavedVecs) return false;
    if (!std::isfinite(value.x) || !std::isfinite(value.y) || !std::isfinite(value.z)) return false;

    saved[savedCount] = { v, v[0], v[1], v[2] };
    ++savedCount;
    v[0] = value.x;
    v[1] = value.y;
    v[2] = value.z;
    return true;
}

float Len(const Vec3& v) {
    return std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
}

Vec3 Normalize(const Vec3& v) {
    const float len = Len(v);
    if (!std::isfinite(len) || len < 0.0001f) return {0.0f, 0.0f, 0.0f};
    const float inv = 1.0f / len;
    return {v.x * inv, v.y * inv, v.z * inv};
}

bool IsFiniteVec(const Vec3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

bool IsReasonableWorldPoint(const Vec3& v) {
    return IsFiniteVec(v) &&
           std::fabs(v.x) < 100000.0f &&
           std::fabs(v.y) < 100000.0f &&
           std::fabs(v.z) < 100000.0f;
}

bool LooksLikeWorldPosition(const Vec3& v) {
    if (!IsReasonableWorldPoint(v)) return false;
    return std::fabs(v.x) > 10.0f ||
           std::fabs(v.y) > 10.0f ||
           std::fabs(v.z) > 10.0f;
}

Vec3 Scale(const Vec3& v, float s) {
    return {v.x * s, v.y * s, v.z * s};
}

Vec3 Add(const Vec3& a, const Vec3& b) {
    return {a.x + b.x, a.y + b.y, a.z + b.z};
}

Vec3 Sub(const Vec3& a, const Vec3& b) {
    return {a.x - b.x, a.y - b.y, a.z - b.z};
}

Vec3 WorldFromLocal(const Vec3& local, const Vec3& right, const Vec3& forward, const Vec3& up) {
    return {
        local.x * right.x + local.y * forward.x + local.z * up.x,
        local.x * right.y + local.y * forward.y + local.z * up.y,
        local.x * right.z + local.y * forward.z + local.z * up.z
    };
}

Vec3 RotateLocalByQuat(const float q[4], const Vec3& v) {
    const float qi = q[0];
    const float qj = q[1];
    const float qk = q[2];
    const float qr = q[3];

    const float tx = 2.0f * (qj * v.z - qk * v.y);
    const float ty = 2.0f * (qk * v.x - qi * v.z);
    const float tz = 2.0f * (qi * v.y - qj * v.x);

    return {
        v.x + qr * tx + (qj * tz - qk * ty),
        v.y + qr * ty + (qk * tx - qi * tz),
        v.z + qr * tz + (qi * ty - qj * tx)
    };
}

bool ReadQuatInverse(const HeadTrackingState& state, float invHead[4]) {
    float head[4] = { state.quat_i, state.quat_j, state.quat_k, state.quat_r };
    const float lenSq = head[0] * head[0] + head[1] * head[1] + head[2] * head[2] + head[3] * head[3];
    if (!std::isfinite(lenSq) || lenSq < 0.5f || lenSq > 1.5f) return false;

    const float invLen = 1.0f / std::sqrt(lenSq);
    invHead[0] = -head[0] * invLen;
    invHead[1] = -head[1] * invLen;
    invHead[2] = -head[2] * invLen;
    invHead[3] =  head[3] * invLen;
    return true;
}

bool ReadVec3At(const void* base, uint32_t offset, Vec3& out) {
    if (!base) return false;

    __try {
        out = *reinterpret_cast<const Vec3*>(reinterpret_cast<const uint8_t*>(base) + offset);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool ReadVec4At(const void* base, uint32_t offset, Vec4& out) {
    if (!base) return false;

    __try {
        out = *reinterpret_cast<const Vec4*>(reinterpret_cast<const uint8_t*>(base) + offset);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool ReadU32Words(const void* base, uint32_t offset, uint32_t* out, uint32_t count) {
    if (!base || !out || count == 0) return false;

    __try {
        const uint32_t* src = reinterpret_cast<const uint32_t*>(reinterpret_cast<const uint8_t*>(base) + offset);
        for (uint32_t i = 0; i < count; ++i) {
            out[i] = src[i];
        }
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool ReadFixedVec3At(const void* base, uint32_t offset, Vec3& out) {
    if (!base) return false;

    __try {
        const int32_t* src = reinterpret_cast<const int32_t*>(reinterpret_cast<const uint8_t*>(base) + offset);
        out = {
            static_cast<float>(src[0]) * 7.6293945e-06f,
            static_cast<float>(src[1]) * 7.6293945e-06f,
            static_cast<float>(src[2]) * 7.6293945e-06f
        };
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool IsValidPivotForTarget(const Vec3& target, const Vec3& pivot, float& distance) {
    if (!LooksLikeWorldPosition(pivot)) return false;

    distance = Len(Sub(target, pivot));
    return std::isfinite(distance) &&
           distance > 5.0f &&
           distance < kMaxShotCompensationDistance;
}

bool FindCameraPivotForTarget(const Vec3& target,
                              Vec3& pivot,
                              uint32_t& pivotKind,
                              uint32_t& pivotOffset,
                              float& pivotDistance) {
    pivot = {};
    pivotKind = 0;
    pivotOffset = 0xffffffffu;
    pivotDistance = 0.0f;

    void* camState = g_diagCamStatePtr.load(std::memory_order_acquire);
    Vec3 candidate{};
    if (ReadVec3At(camState, 0x50, candidate)) {
        float distance = 0.0f;
        if (IsValidPivotForTarget(target, candidate, distance)) {
            pivot = candidate;
            pivotKind = 2;
            pivotOffset = 0x50;
            pivotDistance = distance;
            return true;
        }
    }

    return false;
}

bool UpdateShotVectorWindow(const HeadTrackingState& state, uint64_t nowMs) {
    uint32_t shotReq = state.shot_marker_seq;
    uint32_t restoreReq = state.restore_req_seq;
    uint32_t clickReq = SetLocalOrientationHook_GetClickEdgeSeq();

    bool expected = false;
    if (s_shotVectorWindowPrimed.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
        s_shotVectorWindowShotSeq.store(shotReq, std::memory_order_release);
        s_shotVectorWindowRestoreSeq.store(restoreReq, std::memory_order_release);
        s_shotVectorWindowClickSeq.store(clickReq, std::memory_order_release);
        return false;
    }

    bool opened = false;
    if (shotReq != 0) {
        uint32_t seen = s_shotVectorWindowShotSeq.load(std::memory_order_acquire);
        if (shotReq != seen &&
            s_shotVectorWindowShotSeq.compare_exchange_strong(seen, shotReq, std::memory_order_acq_rel)) {
            opened = true;
        }
    }

    if (restoreReq != 0) {
        uint32_t seen = s_shotVectorWindowRestoreSeq.load(std::memory_order_acquire);
        if (restoreReq != seen &&
            s_shotVectorWindowRestoreSeq.compare_exchange_strong(seen, restoreReq, std::memory_order_acq_rel)) {
            opened = true;
        }
    }

    if (clickReq != 0) {
        uint32_t seen = s_shotVectorWindowClickSeq.load(std::memory_order_acquire);
        if (clickReq != seen &&
            s_shotVectorWindowClickSeq.compare_exchange_strong(seen, clickReq, std::memory_order_acq_rel)) {
            opened = true;
        }
    }

    if (opened) {
        s_shotVectorWindowMs.store(nowMs, std::memory_order_release);
        s_shotVectorWindowLogBudget.store(32, std::memory_order_release);
        s_shotVectorWindowMutateBudget.store(kShotVectorWindowMutateBudget, std::memory_order_release);
    }

    const uint64_t openedAt = s_shotVectorWindowMs.load(std::memory_order_acquire);
    return openedAt != 0 && nowMs >= openedAt && nowMs - openedAt <= kShotVectorWindowMs;
}

bool HasShotVectorMutationBudget() {
    return s_shotVectorWindowMutateBudget.load(std::memory_order_acquire) > 0;
}

void ConsumeShotVectorMutationBudget() {
    uint32_t budget = s_shotVectorWindowMutateBudget.load(std::memory_order_acquire);
    while (budget > 0) {
        if (s_shotVectorWindowMutateBudget.compare_exchange_weak(
                budget, budget - 1, std::memory_order_acq_rel)) {
            return;
        }
    }
}

bool ConsumeShotVectorLogBudget() {
    uint32_t budget = s_shotVectorWindowLogBudget.load(std::memory_order_acquire);
    while (budget > 0) {
        if (s_shotVectorWindowLogBudget.compare_exchange_weak(
                budget, budget - 1, std::memory_order_acq_rel)) {
            return true;
        }
    }
    return false;
}

int32_t FixedFromFloat(float value) {
    if (!std::isfinite(value)) return 0;
    const double scaled = static_cast<double>(value) * 131072.0;
    if (scaled > static_cast<double>(std::numeric_limits<int32_t>::max())) {
        return std::numeric_limits<int32_t>::max();
    }
    if (scaled < static_cast<double>(std::numeric_limits<int32_t>::min())) {
        return std::numeric_limits<int32_t>::min();
    }
    return static_cast<int32_t>(std::llround(scaled));
}

bool FixedNear(int32_t a, int32_t b) {
    const int64_t delta = static_cast<int64_t>(a) - static_cast<int64_t>(b);
    return delta >= -4 && delta <= 4;
}

bool IsRememberedShotVectorMutation(uint8_t* source, const int32_t* fixed) {
    const uint32_t clickSeq = SetLocalOrientationHook_GetClickEdgeSeq();
    if (clickSeq == 0) return false;
    if (s_lastShotVectorClickSeq.load(std::memory_order_acquire) != clickSeq) return false;
    if (s_lastShotVectorSource.load(std::memory_order_acquire) != reinterpret_cast<uintptr_t>(source)) return false;

    return FixedNear(fixed[0], s_lastShotVectorNewX.load(std::memory_order_acquire)) &&
           FixedNear(fixed[1], s_lastShotVectorNewY.load(std::memory_order_acquire)) &&
           FixedNear(fixed[2], s_lastShotVectorNewZ.load(std::memory_order_acquire));
}

void RememberShotVectorMutation(uint8_t* source, const int32_t* fixed) {
    const uint32_t clickSeq = SetLocalOrientationHook_GetClickEdgeSeq();
    if (clickSeq == 0) return;

    s_lastShotVectorNewX.store(fixed[0], std::memory_order_release);
    s_lastShotVectorNewY.store(fixed[1], std::memory_order_release);
    s_lastShotVectorNewZ.store(fixed[2], std::memory_order_release);
    s_lastShotVectorSource.store(reinterpret_cast<uintptr_t>(source), std::memory_order_release);
    s_lastShotVectorClickSeq.store(clickSeq, std::memory_order_release);
}

bool ResolveShotSourceSkipPredicate() {
    if (s_shotSourceSkipPredicate) return true;

    if (!s_exeBase) {
        HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
        if (!hModule) return false;
        s_exeBase = reinterpret_cast<uintptr_t>(hModule);
    }

    s_shotSourceSkipPredicate =
        reinterpret_cast<ShotSourceSkipPredicateFn>(s_exeBase + kShotSourceSkipPredicateOffset);
    return s_shotSourceSkipPredicate != nullptr;
}

bool IsGameSelectedShotSource(uint8_t* source, uint32_t* reasonOut) {
    if (!source) {
        if (reasonOut) *reasonOut = 14;
        return false;
    }
    if (!ResolveShotSourceSkipPredicate()) {
        if (reasonOut) *reasonOut = 15;
        return false;
    }

    __try {
        const uint8_t skip = s_shotSourceSkipPredicate(source + 0x14);
        if (skip != 0) {
            if (reasonOut) *reasonOut = 13;
            return false;
        }
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_shotVectorFaults.fetch_add(1, std::memory_order_relaxed);
        if (reasonOut) *reasonOut = 7;
        return false;
    }
}

bool MutateShotVectorSource(void* shotContext,
                            const HeadTrackingState& state,
                            SavedFixedVec3& saved,
                            Vec3& before,
                            Vec3& after,
                            Vec3& pivot,
                            void** sourceOut,
                            uint32_t* countOut,
                            uint32_t* pivotKindOut,
                            uint32_t* pivotOffsetOut,
                            float* pivotDistanceOut,
                            uint32_t* reasonOut) {
    if (reasonOut) *reasonOut = 0;
    if (pivotKindOut) *pivotKindOut = 0;
    if (pivotOffsetOut) *pivotOffsetOut = 0xffffffffu;
    if (pivotDistanceOut) *pivotDistanceOut = 0.0f;
    if (!shotContext || !sourceOut || !countOut) return false;
    *sourceOut = nullptr;
    *countOut = 0;

    __try {
        uint8_t* context = reinterpret_cast<uint8_t*>(shotContext);
        uint8_t* holder = *reinterpret_cast<uint8_t**>(context + 0x20);
        if (reasonOut) *reasonOut = 2;
        if (!holder) return false;

        const uint32_t count = *reinterpret_cast<uint32_t*>(holder + 0x54);
        uint8_t** entries = *reinterpret_cast<uint8_t***>(holder + 0x48);
        *countOut = count;
        if (reasonOut) *reasonOut = 3;
        if (!entries || count == 0) return false;

        const uint32_t limit = count > 4096 ? 4096 : count;
        if (reasonOut) *reasonOut = count > 4096 ? 4 : 5;
        for (uint32_t i = 0; i < limit; ++i) {
            uint8_t* source = entries[i];
            if (!source) continue;
            if (!IsGameSelectedShotSource(source, reasonOut)) continue;

            int32_t* fixed = reinterpret_cast<int32_t*>(source + 0x70);
            Vec3 current{
                static_cast<float>(fixed[0]) * 7.6293945e-06f,
                static_cast<float>(fixed[1]) * 7.6293945e-06f,
                static_cast<float>(fixed[2]) * 7.6293945e-06f
            };
            if (IsRememberedShotVectorMutation(source, fixed)) {
                if (reasonOut) *reasonOut = 18;
                continue;
            }
            if (!*sourceOut) {
                *sourceOut = source;
                before = current;
            }
            if (IsUnitish(current.x, current.y, current.z)) {
                saved = { fixed, fixed[0], fixed[1], fixed[2] };
                before = current;
                after = current;
                RotateVector(after.x, after.y, after.z, -state.yaw, -state.pitch);
                after = Normalize(after);
                if (reasonOut) *reasonOut = 6;
                if (!IsUnitish(after.x, after.y, after.z)) return false;
                *sourceOut = source;
                fixed[0] = FixedFromFloat(after.x);
                fixed[1] = FixedFromFloat(after.y);
                fixed[2] = FixedFromFloat(after.z);
                RememberShotVectorMutation(source, fixed);
                if (reasonOut) *reasonOut = 0;
                return true;
            }

            if (!IsReasonableWorldPoint(current)) {
                if (reasonOut) *reasonOut = 8;
                continue;
            }
            if (!LooksLikeWorldPosition(current)) {
                if (reasonOut) *reasonOut = 12;
                continue;
            }

            uint32_t pivotKind = 0;
            uint32_t pivotOffset = 0xffffffffu;
            float pivotDistance = 0.0f;
            if (!FindCameraPivotForTarget(current, pivot, pivotKind, pivotOffset, pivotDistance)) {
                Vec3 sourcePivot = *reinterpret_cast<Vec3*>(source + 0x50);
                if (!IsValidPivotForTarget(current, sourcePivot, pivotDistance)) {
                    if (reasonOut) *reasonOut = 11;
                    continue;
                }
                pivot = sourcePivot;
                pivotKind = 3;
                pivotOffset = 0x50;
            }

            if (pivotKindOut) *pivotKindOut = pivotKind;
            if (pivotOffsetOut) *pivotOffsetOut = pivotOffset;
            if (pivotDistanceOut) *pivotDistanceOut = pivotDistance;

            Vec3 delta{
                current.x - pivot.x,
                current.y - pivot.y,
                current.z - pivot.z
            };
            const float distance = Len(delta);
            if (!std::isfinite(distance) || distance < 0.05f || distance > kMaxShotCompensationDistance) {
                if (reasonOut) *reasonOut = 9;
                continue;
            }

            RotateVector(delta.x, delta.y, delta.z, -state.yaw, -state.pitch);
            after = {
                pivot.x + delta.x,
                pivot.y + delta.y,
                pivot.z + delta.z
            };
            if (!IsReasonableWorldPoint(after)) {
                if (reasonOut) *reasonOut = 10;
                return false;
            }

            saved = { fixed, fixed[0], fixed[1], fixed[2] };
            before = current;
            *sourceOut = source;
            fixed[0] = FixedFromFloat(after.x);
            fixed[1] = FixedFromFloat(after.y);
            fixed[2] = FixedFromFloat(after.z);
            RememberShotVectorMutation(source, fixed);
            if (reasonOut) *reasonOut = 0;
            return true;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_shotVectorFaults.fetch_add(1, std::memory_order_relaxed);
        if (reasonOut) *reasonOut = 7;
        return false;
    }

    return false;
}

bool InspectShotVectorSource(void* shotContext, ShotVectorProbe& probe) {
    probe = {};
    probe.reason = 1;
    probe.index = 0xffffffffu;
    if (!shotContext) {
        probe.reason = 2;
        return false;
    }

    __try {
        uint8_t* context = reinterpret_cast<uint8_t*>(shotContext);
        uint8_t* holder = *reinterpret_cast<uint8_t**>(context + 0x20);
        probe.holder = holder;
        if (!holder) {
            probe.reason = 3;
            return false;
        }

        probe.count = *reinterpret_cast<uint32_t*>(holder + 0x54);
        uint8_t** entries = *reinterpret_cast<uint8_t***>(holder + 0x48);
        probe.entries = entries;
        if (!entries || probe.count == 0) {
            probe.reason = 4;
            return false;
        }

        const uint32_t limit = probe.count > 64 ? 64 : probe.count;
        for (uint32_t i = 0; i < limit; ++i) {
            uint8_t* source = entries[i];
            if (!source) continue;
            if (!IsGameSelectedShotSource(source, &probe.reason)) continue;

            int32_t* fixed = reinterpret_cast<int32_t*>(source + 0x70);
            Vec3 current{
                static_cast<float>(fixed[0]) * 7.6293945e-06f,
                static_cast<float>(fixed[1]) * 7.6293945e-06f,
                static_cast<float>(fixed[2]) * 7.6293945e-06f
            };

            if (!probe.source) {
                probe.source = source;
                probe.index = i;
                probe.value = current;
                probe.kind = 3;
                probe.reason = 5;
            }

            if (IsUnitish(current.x, current.y, current.z)) {
                probe.source = source;
                probe.index = i;
                probe.value = current;
                probe.kind = 1;
                probe.reason = 0;
                return true;
            }

            Vec3 origin = *reinterpret_cast<Vec3*>(source + 0x50);
            if (!IsReasonableWorldPoint(current) || !IsReasonableWorldPoint(origin)) {
                continue;
            }

            Vec3 delta{
                current.x - origin.x,
                current.y - origin.y,
                current.z - origin.z
            };
            const float distance = Len(delta);
            if (!std::isfinite(distance) || distance < 0.05f || distance > kMaxShotCompensationDistance) {
                continue;
            }

            probe.source = source;
            probe.index = i;
            probe.value = current;
            probe.origin = origin;
            probe.distance = distance;
            probe.kind = 2;
            probe.reason = 0;
            return true;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_shotVectorFaults.fetch_add(1, std::memory_order_relaxed);
        probe.reason = 7;
        return false;
    }

    return probe.source != nullptr;
}

void RestoreFixed(SavedFixedVec3& saved) {
    if (!saved.ptr) return;

    __try {
        saved.ptr[0] = saved.x;
        saved.ptr[1] = saved.y;
        saved.ptr[2] = saved.z;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_shotVectorFaults.fetch_add(1, std::memory_order_relaxed);
    }
}

bool IsShotInputClassifyReturn(uintptr_t retAddr) {
    if (s_exeBase == 0 || retAddr < s_exeBase) return false;
    const uintptr_t retRva = retAddr - s_exeBase;
    return retRva == kShotInputClassifyReturnProcessorOffset ||
           retRva == kShotInputClassifyReturnAltProcessorOffset;
}

bool MutateShotInputClassifyTarget(void* source,
                                   void* targetPoint,
                                   const HeadTrackingState& state,
                                   Vec4& before,
                                   Vec4& after,
                                   uint32_t* reasonOut) {
    if (reasonOut) *reasonOut = 0;
    if (!source || !targetPoint) {
        if (reasonOut) *reasonOut = 2;
        return false;
    }

    __try {
        Vec4* target = reinterpret_cast<Vec4*>(targetPoint);
        before = *target;
        after = before;

        const Vec3 point{ before.x, before.y, before.z };
        if (!IsReasonableWorldPoint(point) || !std::isfinite(before.w)) {
            if (reasonOut) *reasonOut = 3;
            return false;
        }

        const Vec3 origin = *reinterpret_cast<Vec3*>(reinterpret_cast<uint8_t*>(source) + 0x50);
        if (!IsReasonableWorldPoint(origin)) {
            if (reasonOut) *reasonOut = 4;
            return false;
        }

        Vec3 delta = Sub(point, origin);
        const float distance = Len(delta);
        if (!std::isfinite(distance) || distance < 0.05f || distance > 10000.0f) {
            if (reasonOut) *reasonOut = 5;
            return false;
        }

        RotateVector(delta.x, delta.y, delta.z, -state.yaw, -state.pitch);
        const Vec3 fixed = Add(origin, delta);
        if (!IsReasonableWorldPoint(fixed)) {
            if (reasonOut) *reasonOut = 6;
            return false;
        }

        after.x = fixed.x;
        after.y = fixed.y;
        after.z = fixed.z;
        target->x = after.x;
        target->y = after.y;
        target->z = after.z;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_shotInputClassifyFaults.fetch_add(1, std::memory_order_relaxed);
        if (reasonOut) *reasonOut = 7;
        return false;
    }
}

void RestoreShotInputClassifyTarget(void* targetPoint, const Vec4& before) {
    if (!targetPoint) return;

    __try {
        *reinterpret_cast<Vec4*>(targetPoint) = before;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_shotInputClassifyFaults.fetch_add(1, std::memory_order_relaxed);
    }
}

uint32_t Hook_ShotInputClassify(void* source, void* targetPoint) {
    const uint32_t fires = s_shotInputClassifyCalls.fetch_add(1, std::memory_order_relaxed) + 1;
    const uint32_t totalFires = s_fires.fetch_add(1, std::memory_order_relaxed) + 1;
    const uintptr_t retAddr = reinterpret_cast<uintptr_t>(_ReturnAddress());
    const uintptr_t retRva = (s_exeBase != 0 && retAddr >= s_exeBase) ? (retAddr - s_exeBase) : 0;
    const bool fromShotVector = IsShotInputClassifyReturn(retAddr);

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    const bool hasPose =
        state.enabled &&
        state.applied_frame > 0 &&
        (std::fabs(state.yaw) >= 0.1f ||
         std::fabs(state.pitch) >= 0.1f ||
         std::fabs(state.roll) >= 0.1f);
    const uint64_t nowMs = GetTickCount64();
    const bool inShotWindow = UpdateShotVectorWindow(state, nowMs);

    Vec4 before{};
    Vec4 after{};
    bool mutated = false;
    uint32_t reason = 1;
    uint32_t mutatedCount = 0;
    uint32_t skippedCount = 0;

    if (fromShotVector &&
        kMutateShotInputClassifyTarget &&
        hasPose &&
        inShotWindow &&
        HasShotVectorMutationBudget()) {
        mutated = MutateShotInputClassifyTarget(source, targetPoint, state, before, after, &reason);
    } else if (!hasPose) {
        reason = 17;
    } else if (!inShotWindow) {
        reason = 16;
    } else if (!HasShotVectorMutationBudget()) {
        reason = 18;
    }

    if (mutated) {
        ConsumeShotVectorMutationBudget();
        mutatedCount = s_shotInputClassifyMutated.fetch_add(1, std::memory_order_relaxed) + 1;
        s_compensated.fetch_add(1, std::memory_order_relaxed);
    } else {
        skippedCount = s_shotInputClassifySkipped.fetch_add(1, std::memory_order_relaxed) + 1;
    }

    uint32_t result = 0;
    if (!s_originalShotInputClassify) {
        LogError("[HeadTrackingAim] shot-classify +0x291FDE0 missing original function");
        if (mutated) {
            RestoreShotInputClassifyTarget(targetPoint, before);
        }
        return 0;
    }

    result = s_originalShotInputClassify(source, targetPoint);
    if (mutated) {
        RestoreShotInputClassifyTarget(targetPoint, before);
    }

    if ((fromShotVector && fires <= 64) ||
        (mutated && mutatedCount <= 64) ||
        (!mutated && skippedCount <= 64 && state.applied_frame > 0)) {
        const uint64_t openedAt = s_shotVectorWindowMs.load(std::memory_order_acquire);
        const unsigned long long windowAge = (inShotWindow && nowMs >= openedAt)
            ? static_cast<unsigned long long>(nowMs - openedAt)
            : 0ull;
        LogInfo("[HeadTrackingAim] shot-classify +0x291FDE0 #%u total=%u ret=+0x%llX from_shot=%d mutated=%d reason=%u source=%p target=%p old=(%.4f %.4f %.4f %.4f) new=(%.4f %.4f %.4f %.4f) result=0x%08X enabled=%d applied=%u yaw=%.2f pitch=%.2f click_seq=%u window=%d window_age_ms=%llu mutate_budget=%u",
                fires,
                totalFires,
                static_cast<unsigned long long>(retRva),
                fromShotVector ? 1 : 0,
                mutated ? 1 : 0,
                reason,
                source,
                targetPoint,
                before.x,
                before.y,
                before.z,
                before.w,
                after.x,
                after.y,
                after.z,
                after.w,
                result,
                state.enabled ? 1 : 0,
                state.applied_frame,
                state.yaw,
                state.pitch,
                SetLocalOrientationHook_GetClickEdgeSeq(),
                inShotWindow ? 1 : 0,
                windowAge,
                s_shotVectorWindowMutateBudget.load(std::memory_order_acquire));
    }

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = totalFires;
    }

    return result;
}

struct ShotQueueEntrySnapshot {
    void* entry;
    uint64_t p0;
    uint64_t p8;
    uint32_t v10;
    uint16_t v14;
    uint32_t v18;
    uint16_t v1c;
    int32_t source70;
    int32_t source74;
    int32_t source78;
};

uint8_t* ShotQueueEntryPtr(void* state, uint32_t startIndex, uint32_t localIndex, bool alternateQueue) {
    if (!state) return nullptr;
    const uint64_t entryIndex = alternateQueue
        ? static_cast<uint64_t>(startIndex) + localIndex
        : static_cast<uint64_t>(localIndex);
    if (entryIndex >= 0x13880) return nullptr;

    const uint32_t baseOffset = alternateQueue ? 0x17A98u : 0x324EA0u;
    return reinterpret_cast<uint8_t*>(state) + baseOffset + entryIndex * 0x20;
}

bool ReadShotQueueEntry(void* state,
                        uint32_t startIndex,
                        uint32_t localIndex,
                        bool alternateQueue,
                        ShotQueueEntrySnapshot& out) {
    uint8_t* entry = ShotQueueEntryPtr(state, startIndex, localIndex, alternateQueue);
    if (!entry) return false;

    __try {
        out.entry = entry;
        out.p0 = *reinterpret_cast<uint64_t*>(entry);
        out.p8 = *reinterpret_cast<uint64_t*>(entry + 0x8);
        out.v10 = *reinterpret_cast<uint32_t*>(entry + 0x10);
        out.v14 = *reinterpret_cast<uint16_t*>(entry + 0x14);
        out.v18 = *reinterpret_cast<uint32_t*>(entry + 0x18);
        out.v1c = *reinterpret_cast<uint16_t*>(entry + 0x1C);
        out.source70 = 0;
        out.source74 = 0;
        out.source78 = 0;
        if (out.p0 != 0) {
            uint8_t* source = reinterpret_cast<uint8_t*>(out.p0);
            out.source70 = *reinterpret_cast<int32_t*>(source + 0x70);
            out.source74 = *reinterpret_cast<int32_t*>(source + 0x74);
            out.source78 = *reinterpret_cast<int32_t*>(source + 0x78);
        }
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_shotQueueConsumerFaults.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
}

uint32_t MutateShotQueueSources(void* state,
                                uint32_t startIndex,
                                uint32_t count,
                                bool alternateQueue,
                                const HeadTrackingState& ht,
                                SavedFixedVec3* saved,
                                uint32_t maxSaved,
                                Vec3& before,
                                Vec3& after,
                                Vec3& pivot,
                                void** sourceOut,
                                uint32_t* entryIndexOut,
                                uint32_t* pivotKindOut,
                                uint32_t* pivotOffsetOut,
                                float* pivotDistanceOut,
                                uint32_t* reasonOut) {
    if (reasonOut) *reasonOut = 0;
    if (sourceOut) *sourceOut = nullptr;
    if (entryIndexOut) *entryIndexOut = 0xffffffffu;
    if (pivotKindOut) *pivotKindOut = 0;
    if (pivotOffsetOut) *pivotOffsetOut = 0xffffffffu;
    if (pivotDistanceOut) *pivotDistanceOut = 0.0f;
    if (!state || !saved || maxSaved == 0 || count == 0) {
        if (reasonOut) *reasonOut = 2;
        return 0;
    }

    uint32_t changed = 0;
    uint32_t lastReason = 13;

    __try {
        uint32_t limit = count;
        if (limit > maxSaved) limit = maxSaved;
        if (limit > 128) limit = 128;

        for (uint32_t i = 0; i < limit; ++i) {
            uint8_t* entry = ShotQueueEntryPtr(state, startIndex, i, alternateQueue);
            if (!entry) {
                lastReason = 3;
                continue;
            }

            uint8_t* source = *reinterpret_cast<uint8_t**>(entry);
            if (!source) {
                lastReason = 4;
                continue;
            }

            int32_t* fixed = reinterpret_cast<int32_t*>(source + 0x70);
            Vec3 current{
                static_cast<float>(fixed[0]) * 7.6293945e-06f,
                static_cast<float>(fixed[1]) * 7.6293945e-06f,
                static_cast<float>(fixed[2]) * 7.6293945e-06f
            };

            if (!IsReasonableWorldPoint(current)) {
                lastReason = 8;
                continue;
            }
            if (!LooksLikeWorldPosition(current)) {
                lastReason = 12;
                continue;
            }

            Vec3 localPivot{};
            uint32_t localPivotKind = 0;
            uint32_t localPivotOffset = 0xffffffffu;
            float localPivotDistance = 0.0f;
            if (!FindCameraPivotForTarget(current, localPivot, localPivotKind, localPivotOffset, localPivotDistance)) {
                Vec3 sourcePivot = *reinterpret_cast<Vec3*>(source + 0x50);
                if (!IsValidPivotForTarget(current, sourcePivot, localPivotDistance)) {
                    lastReason = 11;
                    continue;
                }
                localPivot = sourcePivot;
                localPivotKind = 3;
                localPivotOffset = 0x50;
            }

            Vec3 delta{
                current.x - localPivot.x,
                current.y - localPivot.y,
                current.z - localPivot.z
            };
            const float distance = Len(delta);
            if (!std::isfinite(distance) || distance < 0.05f || distance > kMaxShotCompensationDistance) {
                lastReason = 9;
                continue;
            }

            RotateVector(delta.x, delta.y, delta.z, -ht.yaw, -ht.pitch);
            Vec3 next{
                localPivot.x + delta.x,
                localPivot.y + delta.y,
                localPivot.z + delta.z
            };
            if (!IsReasonableWorldPoint(next)) {
                lastReason = 10;
                continue;
            }

            if (changed == 0) {
                before = current;
                after = next;
                pivot = localPivot;
                if (sourceOut) *sourceOut = source;
                if (entryIndexOut) *entryIndexOut = alternateQueue ? startIndex + i : i;
                if (pivotKindOut) *pivotKindOut = localPivotKind;
                if (pivotOffsetOut) *pivotOffsetOut = localPivotOffset;
                if (pivotDistanceOut) *pivotDistanceOut = localPivotDistance;
            }

            saved[changed] = { fixed, fixed[0], fixed[1], fixed[2] };
            fixed[0] = FixedFromFloat(next.x);
            fixed[1] = FixedFromFloat(next.y);
            fixed[2] = FixedFromFloat(next.z);
            ++changed;
            lastReason = 0;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_shotQueueConsumerFaults.fetch_add(1, std::memory_order_relaxed);
        if (reasonOut) *reasonOut = 7;
        return changed;
    }

    if (reasonOut) *reasonOut = lastReason;
    return changed;
}

void Hook_ShotQueueConsumer(void* state,
                            void* context,
                            void* scratch,
                            uint32_t arg4,
                            uint32_t count,
                            uint32_t arg6,
                            uint32_t arg7) {
    const uint32_t calls = s_shotQueueConsumerCalls.fetch_add(1, std::memory_order_relaxed) + 1;
    const uint32_t totalFires = s_fires.fetch_add(1, std::memory_order_relaxed) + 1;
    const bool alternateQueue = arg6 != 0;

    uint32_t queueA = 0;
    uint32_t queueB = 0;
    bool haveCounts = false;
    __try {
        if (state) {
            queueA = *reinterpret_cast<uint32_t*>(reinterpret_cast<uint8_t*>(state) + 0x17A88);
            queueB = *reinterpret_cast<uint32_t*>(reinterpret_cast<uint8_t*>(state) + 0x17A8C);
            haveCounts = true;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_shotQueueConsumerFaults.fetch_add(1, std::memory_order_relaxed);
    }

    ShotQueueEntrySnapshot first{};
    const bool haveFirst = ReadShotQueueEntry(state, arg4, 0, alternateQueue, first);

    HeadTrackingState ht{};
    if (g_sharedState.IsAvailable()) {
        ht = g_sharedState.Read();
    }

    const bool hasPose =
        ht.enabled &&
        ht.applied_frame > 0 &&
        (std::fabs(ht.yaw) >= 0.1f ||
         std::fabs(ht.pitch) >= 0.1f ||
         std::fabs(ht.roll) >= 0.1f);
    const uint64_t nowMs = GetTickCount64();
    const bool inShotVectorWindow = UpdateShotVectorWindow(ht, nowMs);

    SavedFixedVec3 saved[128]{};
    Vec3 before{};
    Vec3 after{};
    Vec3 pivot{};
    void* source = nullptr;
    uint32_t entryIndex = 0xffffffffu;
    uint32_t pivotKind = 0;
    uint32_t pivotOffset = 0xffffffffu;
    float pivotDistance = 0.0f;
    uint32_t reason = 1;
    uint32_t changed = 0;

    if (kMutateShotQueueConsumerSources &&
        hasPose &&
        inShotVectorWindow &&
        HasShotVectorMutationBudget()) {
        changed = MutateShotQueueSources(state,
                                         arg4,
                                         count,
                                         alternateQueue,
                                         ht,
                                         saved,
                                         static_cast<uint32_t>(sizeof(saved) / sizeof(saved[0])),
                                         before,
                                         after,
                                         pivot,
                                         &source,
                                         &entryIndex,
                                         &pivotKind,
                                         &pivotOffset,
                                         &pivotDistance,
                                         &reason);
    }

    uint32_t mutatedCount = 0;
    uint32_t skippedCount = 0;
    if (changed != 0) {
        ConsumeShotVectorMutationBudget();
        mutatedCount = s_shotQueueConsumerMutated.fetch_add(1, std::memory_order_relaxed) + 1;
        s_compensated.fetch_add(changed, std::memory_order_relaxed);
    } else {
        skippedCount = s_shotQueueConsumerSkipped.fetch_add(1, std::memory_order_relaxed) + 1;
    }

    const bool logShotWindow = inShotVectorWindow && ConsumeShotVectorLogBudget();
    const uint64_t openedAt = s_shotVectorWindowMs.load(std::memory_order_acquire);
    const unsigned long long windowAge = (inShotVectorWindow && nowMs >= openedAt)
        ? static_cast<unsigned long long>(nowMs - openedAt)
        : 0ull;

    if (logShotWindow ||
        calls <= 96 ||
        count != 0 ||
        (changed != 0 && mutatedCount <= 32) ||
        (changed == 0 && skippedCount <= 32 && ht.applied_frame > 0)) {
        LogInfo("[HeadTrackingAim] shot-queue +0x291ED20 #%u total=%u mutated=%u reason=%u state=%p context=%p scratch=%p args=(%u,%u,%u,%u) queue_select=%u counts_ok=%d queueA=%u queueB=%u first_ok=%d entry=%p p0=0x%llX p8=0x%llX v10=%u v14=%u v18=0x%08X v1c=0x%04X src70=(%d,%d,%d) source=%p entry_index=%u value=(%.4f %.4f %.4f) new=(%.4f %.4f %.4f) pivot_kind=%u pivot_off=0x%X pivot=(%.4f %.4f %.4f) pivot_dist=%.2f enabled=%d applied=%u yaw=%.2f pitch=%.2f req=%u shot_seq=%u ack=%u window=%d window_age_ms=%llu mutate_budget=%u",
                calls,
                totalFires,
                changed,
                reason,
                state,
                context,
                scratch,
                arg4,
                count,
                arg6,
                arg7,
                alternateQueue ? 1u : 0u,
                haveCounts ? 1 : 0,
                queueA,
                queueB,
                haveFirst ? 1 : 0,
                first.entry,
                static_cast<unsigned long long>(first.p0),
                static_cast<unsigned long long>(first.p8),
                first.v10,
                first.v14,
                first.v18,
                first.v1c,
                first.source70,
                first.source74,
                first.source78,
                source,
                entryIndex,
                before.x,
                before.y,
                before.z,
                after.x,
                after.y,
                after.z,
                pivotKind,
                pivotOffset,
                pivot.x,
                pivot.y,
                pivot.z,
                pivotDistance,
                ht.enabled ? 1 : 0,
                ht.applied_frame,
                ht.yaw,
                ht.pitch,
                ht.restore_req_seq,
                ht.shot_marker_seq,
                ht.restore_ack_seq,
                inShotVectorWindow ? 1 : 0,
                windowAge,
                s_shotVectorWindowMutateBudget.load(std::memory_order_acquire));
    }

    if (s_originalShotQueueConsumer) {
        s_originalShotQueueConsumer(state, context, scratch, arg4, count, arg6, arg7);
    }

    for (uint32_t i = 0; i < changed; ++i) {
        RestoreFixed(saved[i]);
    }

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = totalFires;
    }
}

struct ShotQueueBuildSnapshot {
    uint32_t stateValue;
    uint32_t stateCapacity;
    uint32_t builderQueueCount;
    uint32_t builderCandidateCount;
    uint32_t builderCursor;
    uint32_t builderFlag;
    uint32_t builderField1e144;
    uint32_t builderField1e154;
    uint32_t candidateCount;
    uint32_t computedStride;
    uint32_t computedEnd;
};

bool ReadShotQueueBuildSnapshot(void* statePtr,
                                void* builder,
                                void* candidateOut,
                                ShotQueueBuildSnapshot& snapshot) {
    snapshot = {};
    if (!statePtr || !builder || !candidateOut) return false;

    __try {
        const uint8_t* stateBytes = reinterpret_cast<const uint8_t*>(statePtr);
        const uint8_t* builderBytes = reinterpret_cast<const uint8_t*>(builder);
        const uint8_t* candidateBytes = reinterpret_cast<const uint8_t*>(candidateOut);

        snapshot.stateValue = *reinterpret_cast<const uint32_t*>(stateBytes + 0x17804);
        snapshot.stateCapacity = *reinterpret_cast<const uint32_t*>(stateBytes + 0x17808);
        snapshot.builderQueueCount = *reinterpret_cast<const uint32_t*>(builderBytes + 0x1c);
        snapshot.builderCandidateCount = *reinterpret_cast<const uint32_t*>(builderBytes + 0x2c);
        snapshot.builderField1e144 = *reinterpret_cast<const uint32_t*>(builderBytes + 0x1e144);
        snapshot.builderFlag = *reinterpret_cast<const uint8_t*>(builderBytes + 0x1e14c);
        snapshot.builderField1e154 = *reinterpret_cast<const uint32_t*>(builderBytes + 0x1e154);
        snapshot.builderCursor = *reinterpret_cast<const uint32_t*>(builderBytes + 0x1e158);
        snapshot.candidateCount = *reinterpret_cast<const uint32_t*>(candidateBytes + 0x14);
        snapshot.computedStride = snapshot.builderFlag != 0 ? 8 : 12;
        snapshot.computedEnd = snapshot.builderCursor + snapshot.computedStride * snapshot.candidateCount;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_shotQueueBuildFaults.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
}

bool Hook_ShotQueueBuild(void* statePtr,
                         void* builder,
                         void* context,
                         void* weapon,
                         uint64_t slotArg,
                         uint64_t candidateIndexArg,
                         void* candidateOut) {
    const uint32_t calls = s_shotQueueBuildCalls.fetch_add(1, std::memory_order_relaxed) + 1;
    const uint32_t totalFires = s_fires.fetch_add(1, std::memory_order_relaxed) + 1;

    uint32_t beforeWords[16]{};
    uint32_t afterWords[16]{};
    ShotQueueBuildSnapshot beforeSnapshot{};
    ShotQueueBuildSnapshot afterSnapshot{};
    const bool beforeWordsOk = ReadU32Words(candidateOut, 0, beforeWords, 16);
    const bool beforeSnapshotOk = ReadShotQueueBuildSnapshot(statePtr, builder, candidateOut, beforeSnapshot);

    if (!s_originalShotQueueBuild) {
        LogError("[HeadTrackingAim] shot-build +0x291F968 missing original function");
        return false;
    }

    const bool result = s_originalShotQueueBuild(statePtr,
                                                 builder,
                                                 context,
                                                 weapon,
                                                 slotArg,
                                                 candidateIndexArg,
                                                 candidateOut);

    const bool afterWordsOk = ReadU32Words(candidateOut, 0, afterWords, 16);
    const bool afterSnapshotOk = ReadShotQueueBuildSnapshot(statePtr, builder, candidateOut, afterSnapshot);
    if (!beforeWordsOk || !afterWordsOk || !beforeSnapshotOk || !afterSnapshotOk) {
        s_shotQueueBuildFaults.fetch_add(1, std::memory_order_relaxed);
    }

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    const uint64_t nowMs = GetTickCount64();
    const bool inShotVectorWindow = UpdateShotVectorWindow(state, nowMs);
    const bool logShotWindow = inShotVectorWindow && ConsumeShotVectorLogBudget();
    const uint64_t openedAt = s_shotVectorWindowMs.load(std::memory_order_acquire);
    const unsigned long long windowAge = (inShotVectorWindow && nowMs >= openedAt)
        ? static_cast<unsigned long long>(nowMs - openedAt)
        : 0ull;

    if (logShotWindow || (calls <= 8 && state.applied_frame > 0)) {
        LogInfo("[HeadTrackingAim] shot-build +0x291F968 #%u total=%u result=%d state=%p builder=%p ctx=%p weapon=%p slot=%llu cand=%llu out=%p snap_ok=(%d,%d) words_ok=(%d,%d) before_state=(val=%u cap=%u q=%u c=%u cursor=%u flag=%u f144=%u f154=%u cand_count=%u stride=%u end=%u) after_state=(val=%u cap=%u q=%u c=%u cursor=%u flag=%u f144=%u f154=%u cand_count=%u stride=%u end=%u) before=[%08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X] after=[%08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X] enabled=%d applied=%u yaw=%.2f pitch=%.2f req=%u shot_seq=%u ack=%u window=%d window_age_ms=%llu",
                calls,
                totalFires,
                result ? 1 : 0,
                statePtr,
                builder,
                context,
                weapon,
                static_cast<unsigned long long>(slotArg),
                static_cast<unsigned long long>(candidateIndexArg),
                candidateOut,
                beforeSnapshotOk ? 1 : 0,
                afterSnapshotOk ? 1 : 0,
                beforeWordsOk ? 1 : 0,
                afterWordsOk ? 1 : 0,
                beforeSnapshot.stateValue,
                beforeSnapshot.stateCapacity,
                beforeSnapshot.builderQueueCount,
                beforeSnapshot.builderCandidateCount,
                beforeSnapshot.builderCursor,
                beforeSnapshot.builderFlag,
                beforeSnapshot.builderField1e144,
                beforeSnapshot.builderField1e154,
                beforeSnapshot.candidateCount,
                beforeSnapshot.computedStride,
                beforeSnapshot.computedEnd,
                afterSnapshot.stateValue,
                afterSnapshot.stateCapacity,
                afterSnapshot.builderQueueCount,
                afterSnapshot.builderCandidateCount,
                afterSnapshot.builderCursor,
                afterSnapshot.builderFlag,
                afterSnapshot.builderField1e144,
                afterSnapshot.builderField1e154,
                afterSnapshot.candidateCount,
                afterSnapshot.computedStride,
                afterSnapshot.computedEnd,
                beforeWords[0],
                beforeWords[1],
                beforeWords[2],
                beforeWords[3],
                beforeWords[4],
                beforeWords[5],
                beforeWords[6],
                beforeWords[7],
                beforeWords[8],
                beforeWords[9],
                beforeWords[10],
                beforeWords[11],
                beforeWords[12],
                beforeWords[13],
                beforeWords[14],
                beforeWords[15],
                afterWords[0],
                afterWords[1],
                afterWords[2],
                afterWords[3],
                afterWords[4],
                afterWords[5],
                afterWords[6],
                afterWords[7],
                afterWords[8],
                afterWords[9],
                afterWords[10],
                afterWords[11],
                afterWords[12],
                afterWords[13],
                afterWords[14],
                afterWords[15],
                state.enabled ? 1 : 0,
                state.applied_frame,
                state.yaw,
                state.pitch,
                state.restore_req_seq,
                state.shot_marker_seq,
                state.restore_ack_seq,
                inShotVectorWindow ? 1 : 0,
                windowAge);
    }

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = totalFires;
    }

    return result;
}

struct ShotCandidateWriterChange {
    uint32_t encoding;
    uint32_t offset;
    Vec3 before;
    Vec3 after;
    Vec3 pivot;
    uint32_t pivotKind;
    uint32_t pivotOffset;
    float pivotDistance;
};

bool BuildCompensatedWorldPoint(const Vec3& current,
                                const HeadTrackingState& state,
                                Vec3& next,
                                Vec3& pivot,
                                uint32_t& pivotKind,
                                uint32_t& pivotOffset,
                                float& pivotDistance) {
    if (!LooksLikeWorldPosition(current)) return false;
    if (!FindCameraPivotForTarget(current, pivot, pivotKind, pivotOffset, pivotDistance)) return false;

    Vec3 delta = Sub(current, pivot);
    const float distance = Len(delta);
    if (!std::isfinite(distance) || distance < 0.05f || distance > kMaxShotCompensationDistance) return false;

    RotateVector(delta.x, delta.y, delta.z, -state.yaw, -state.pitch);
    next = Add(pivot, delta);
    return IsReasonableWorldPoint(next);
}

bool BuildFinalVectorReplacement(void* vector,
                                 const HeadTrackingState& state,
                                 uint32_t replacement[4],
                                 uint32_t& encoding,
                                 Vec3& before,
                                 Vec3& after,
                                 Vec3& pivot,
                                 uint32_t& pivotKind,
                                 uint32_t& pivotOffset,
                                 float& pivotDistance,
                                 uint32_t& reason) {
    encoding = 0;
    before = {};
    after = {};
    pivot = {};
    pivotKind = 0;
    pivotOffset = 0xffffffffu;
    pivotDistance = 0.0f;
    reason = 0;
    if (!vector) {
        reason = 2;
        return false;
    }

    __try {
        std::memcpy(replacement, vector, sizeof(uint32_t) * 4);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_shotFinalVectorWriteFaults.fetch_add(1, std::memory_order_relaxed);
        reason = 7;
        return false;
    }

    float* floats = reinterpret_cast<float*>(replacement);
    const Vec3 floatPoint{floats[0], floats[1], floats[2]};
    if (LooksLikeWorldPosition(floatPoint)) {
        Vec3 next{};
        if (!BuildCompensatedWorldPoint(floatPoint, state, next, pivot, pivotKind, pivotOffset, pivotDistance)) {
            reason = 4;
            return false;
        }

        before = floatPoint;
        after = next;
        floats[0] = next.x;
        floats[1] = next.y;
        floats[2] = next.z;
        encoding = 1;
        return true;
    }

    int32_t* fixed = reinterpret_cast<int32_t*>(replacement);
    const Vec3 fixedPoint{
        static_cast<float>(fixed[0]) * 7.6293945e-06f,
        static_cast<float>(fixed[1]) * 7.6293945e-06f,
        static_cast<float>(fixed[2]) * 7.6293945e-06f
    };
    if (!LooksLikeWorldPosition(fixedPoint)) {
        reason = 5;
        return false;
    }

    Vec3 next{};
    if (!BuildCompensatedWorldPoint(fixedPoint, state, next, pivot, pivotKind, pivotOffset, pivotDistance)) {
        reason = 6;
        return false;
    }

    before = fixedPoint;
    after = next;
    fixed[0] = FixedFromFloat(next.x);
    fixed[1] = FixedFromFloat(next.y);
    fixed[2] = FixedFromFloat(next.z);
    encoding = 2;
    return true;
}

void Hook_ShotFinalVectorWrite(void* engineState, int index, uint32_t vectorCount, void* vector, void* payload) {
    const uint32_t calls = s_shotFinalVectorWriteCalls.fetch_add(1, std::memory_order_relaxed) + 1;
    const uint32_t totalFires = s_fires.fetch_add(1, std::memory_order_relaxed) + 1;

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    const bool hasPose =
        state.enabled &&
        state.applied_frame > 0 &&
        (std::fabs(state.yaw) >= 0.1f ||
         std::fabs(state.pitch) >= 0.1f ||
         std::fabs(state.roll) >= 0.1f);
    const uint64_t nowMs = GetTickCount64();
    const bool inShotVectorWindow = UpdateShotVectorWindow(state, nowMs);
    const bool logShotWindow = inShotVectorWindow && ConsumeShotVectorLogBudget();
    const uint64_t openedAt = s_shotVectorWindowMs.load(std::memory_order_acquire);
    const unsigned long long windowAge = (inShotVectorWindow && nowMs >= openedAt)
        ? static_cast<unsigned long long>(nowMs - openedAt)
        : 0ull;

    uint32_t replacement[4]{};
    uint32_t encoding = 0;
    Vec3 before{};
    Vec3 after{};
    Vec3 pivot{};
    uint32_t pivotKind = 0;
    uint32_t pivotOffset = 0xffffffffu;
    float pivotDistance = 0.0f;
    uint32_t reason = 1;
    bool mutated = false;

    if (kMutateShotFinalVectorWrite && hasPose && inShotVectorWindow && HasShotVectorMutationBudget()) {
        mutated = BuildFinalVectorReplacement(vector,
                                              state,
                                              replacement,
                                              encoding,
                                              before,
                                              after,
                                              pivot,
                                              pivotKind,
                                              pivotOffset,
                                              pivotDistance,
                                              reason);
    } else {
        reason = hasPose ? 16u : 17u;
    }

    uint32_t mutatedCount = 0;
    uint32_t skippedCount = 0;
    if (mutated) {
        ConsumeShotVectorMutationBudget();
        mutatedCount = s_shotFinalVectorWriteMutated.fetch_add(1, std::memory_order_relaxed) + 1;
        s_compensated.fetch_add(1, std::memory_order_relaxed);
    } else {
        skippedCount = s_shotFinalVectorWriteSkipped.fetch_add(1, std::memory_order_relaxed) + 1;
    }

    uint32_t raw0 = 0;
    uint32_t raw1 = 0;
    uint32_t raw2 = 0;
    uint32_t raw3 = 0;
    if (vector) {
        __try {
            const uint32_t* raw = reinterpret_cast<const uint32_t*>(vector);
            raw0 = raw[0];
            raw1 = raw[1];
            raw2 = raw[2];
            raw3 = raw[3];
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            s_shotFinalVectorWriteFaults.fetch_add(1, std::memory_order_relaxed);
        }
    }

    if (logShotWindow ||
        (mutated && mutatedCount <= 32) ||
        (!mutated && skippedCount <= 16 && state.applied_frame > 0)) {
        LogInfo("[HeadTrackingAim] shot-final +0x29216D0 #%u total=%u mutated=%d reason=%u enc=%u state=%p index=%d count=%u vector=%p payload=%p raw=[%08X %08X %08X %08X] value=(%.4f %.4f %.4f) new=(%.4f %.4f %.4f) pivot_kind=%u pivot_off=0x%X pivot=(%.4f %.4f %.4f) pivot_dist=%.2f enabled=%d applied=%u yaw=%.2f pitch=%.2f pending=%d req=%u shot_seq=%u click_seq=%u ack=%u window=%d window_age_ms=%llu mutate_budget=%u",
                calls,
                totalFires,
                mutated ? 1 : 0,
                reason,
                encoding,
                engineState,
                index,
                vectorCount,
                vector,
                payload,
                raw0,
                raw1,
                raw2,
                raw3,
                before.x,
                before.y,
                before.z,
                after.x,
                after.y,
                after.z,
                pivotKind,
                pivotOffset,
                pivot.x,
                pivot.y,
                pivot.z,
                pivotDistance,
                state.enabled ? 1 : 0,
                state.applied_frame,
                state.yaw,
                state.pitch,
                state.pending_native_restore ? 1 : 0,
                state.restore_req_seq,
                state.shot_marker_seq,
                SetLocalOrientationHook_GetClickEdgeSeq(),
                state.restore_ack_seq,
                inShotVectorWindow ? 1 : 0,
                windowAge,
                s_shotVectorWindowMutateBudget.load(std::memory_order_acquire));
    }

    if (!s_originalShotFinalVectorWrite) {
        LogError("[HeadTrackingAim] shot-final +0x29216D0 missing original function");
        return;
    }

    s_originalShotFinalVectorWrite(engineState,
                                   index,
                                   vectorCount,
                                   mutated ? replacement : vector,
                                   payload);

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = totalFires;
    }
}

uint32_t ScanShotCandidateWriterOutput(void* out,
                                       const HeadTrackingState& state,
                                       bool applyWrites,
                                       ShotCandidateWriterChange& firstChange,
                                       uint32_t* reasonOut) {
    if (reasonOut) *reasonOut = 0;
    firstChange = {};
    if (!out) {
        if (reasonOut) *reasonOut = 2;
        return 0;
    }

    uint32_t changed = 0;
    uint32_t lastReason = 3;
    constexpr uint32_t kScanBytes = 0x220;
    constexpr uint32_t kMaxChanges = 12;
    uint8_t* base = reinterpret_cast<uint8_t*>(out);

    __try {
        for (uint32_t offset = 0; offset + sizeof(Vec3) <= kScanBytes && changed < kMaxChanges; offset += 4) {
            Vec3 current = *reinterpret_cast<Vec3*>(base + offset);
            Vec3 next{};
            Vec3 pivot{};
            uint32_t pivotKind = 0;
            uint32_t pivotOffset = 0xffffffffu;
            float pivotDistance = 0.0f;
            if (!BuildCompensatedWorldPoint(current, state, next, pivot, pivotKind, pivotOffset, pivotDistance)) {
                lastReason = 4;
                continue;
            }

            if (applyWrites) {
                *reinterpret_cast<Vec3*>(base + offset) = next;
            }
            if (changed == 0) {
                firstChange = {1, offset, current, next, pivot, pivotKind, pivotOffset, pivotDistance};
            }
            ++changed;
            lastReason = 0;
        }

        for (uint32_t offset = 0; offset + sizeof(int32_t) * 3 <= kScanBytes && changed < kMaxChanges; offset += 4) {
            int32_t* fixed = reinterpret_cast<int32_t*>(base + offset);
            Vec3 current{
                static_cast<float>(fixed[0]) * 7.6293945e-06f,
                static_cast<float>(fixed[1]) * 7.6293945e-06f,
                static_cast<float>(fixed[2]) * 7.6293945e-06f
            };

            Vec3 next{};
            Vec3 pivot{};
            uint32_t pivotKind = 0;
            uint32_t pivotOffset = 0xffffffffu;
            float pivotDistance = 0.0f;
            if (!BuildCompensatedWorldPoint(current, state, next, pivot, pivotKind, pivotOffset, pivotDistance)) {
                lastReason = 5;
                continue;
            }

            if (applyWrites) {
                fixed[0] = FixedFromFloat(next.x);
                fixed[1] = FixedFromFloat(next.y);
                fixed[2] = FixedFromFloat(next.z);
            }
            if (changed == 0) {
                firstChange = {2, offset, current, next, pivot, pivotKind, pivotOffset, pivotDistance};
            }
            ++changed;
            lastReason = 0;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_shotCandidateWriterFaults.fetch_add(1, std::memory_order_relaxed);
        if (reasonOut) *reasonOut = 7;
        return changed;
    }

    if (reasonOut) *reasonOut = lastReason;
    return changed;
}

void Hook_ShotCandidateWriter(void* source,
                              void* context,
                              void* weapon,
                              uint8_t slot,
                              int candidateIndex,
                              uint32_t stateValue,
                              int startIndex,
                              void* out) {
    const uint32_t calls = s_shotCandidateWriterCalls.fetch_add(1, std::memory_order_relaxed) + 1;
    const uint32_t totalFires = s_fires.fetch_add(1, std::memory_order_relaxed) + 1;

    if (!s_originalShotCandidateWriter) {
        LogError("[HeadTrackingAim] shot-writer +0x2930410 missing original function");
        return;
    }

    s_originalShotCandidateWriter(source, context, weapon, slot, candidateIndex, stateValue, startIndex, out);

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    const bool hasPose =
        state.enabled &&
        state.applied_frame > 0 &&
        (std::fabs(state.yaw) >= 0.1f ||
         std::fabs(state.pitch) >= 0.1f ||
         std::fabs(state.roll) >= 0.1f);
    const uint64_t nowMs = GetTickCount64();
    const bool inShotVectorWindow = UpdateShotVectorWindow(state, nowMs);
    const bool logShotWindow = inShotVectorWindow && ConsumeShotVectorLogBudget();

    ShotCandidateWriterChange firstChange{};
    uint32_t reason = 1;
    uint32_t matches = 0;
    if ((logShotWindow || (kMutateShotCandidateWriterOutput && HasShotVectorMutationBudget())) &&
        hasPose &&
        inShotVectorWindow) {
        matches = ScanShotCandidateWriterOutput(out,
                                                state,
                                                kMutateShotCandidateWriterOutput,
                                                firstChange,
                                                &reason);
    }

    uint32_t mutatedCount = 0;
    if (kMutateShotCandidateWriterOutput && matches != 0) {
        ConsumeShotVectorMutationBudget();
        mutatedCount = s_shotCandidateWriterMutated.fetch_add(1, std::memory_order_relaxed) + 1;
        s_compensated.fetch_add(matches, std::memory_order_relaxed);
    } else {
        s_shotCandidateWriterSkipped.fetch_add(1, std::memory_order_relaxed);
    }

    const uint64_t openedAt = s_shotVectorWindowMs.load(std::memory_order_acquire);
    const unsigned long long windowAge = (inShotVectorWindow && nowMs >= openedAt)
        ? static_cast<unsigned long long>(nowMs - openedAt)
        : 0ull;

    if (logShotWindow ||
        (kMutateShotCandidateWriterOutput && matches != 0 && mutatedCount <= 64)) {
        LogInfo("[HeadTrackingAim] shot-writer +0x2930410 #%u total=%u matches=%u mutated=%u reason=%u src=%p ctx=%p weapon=%p slot=%u cand=%d state_val=%u start=%d out=%p enc=%u off=0x%X value=(%.4f %.4f %.4f) new=(%.4f %.4f %.4f) pivot_kind=%u pivot_off=0x%X pivot=(%.4f %.4f %.4f) pivot_dist=%.2f enabled=%d applied=%u yaw=%.2f pitch=%.2f req=%u shot_seq=%u ack=%u window=%d window_age_ms=%llu mutate_budget=%u",
                calls,
                totalFires,
                matches,
                kMutateShotCandidateWriterOutput && matches != 0 ? matches : 0,
                reason,
                source,
                context,
                weapon,
                static_cast<unsigned int>(slot),
                candidateIndex,
                stateValue,
                startIndex,
                out,
                firstChange.encoding,
                firstChange.offset,
                firstChange.before.x,
                firstChange.before.y,
                firstChange.before.z,
                firstChange.after.x,
                firstChange.after.y,
                firstChange.after.z,
                firstChange.pivotKind,
                firstChange.pivotOffset,
                firstChange.pivot.x,
                firstChange.pivot.y,
                firstChange.pivot.z,
                firstChange.pivotDistance,
                state.enabled ? 1 : 0,
                state.applied_frame,
                state.yaw,
                state.pitch,
                state.restore_req_seq,
                state.shot_marker_seq,
                state.restore_ack_seq,
                inShotVectorWindow ? 1 : 0,
                windowAge,
                s_shotVectorWindowMutateBudget.load(std::memory_order_acquire));
    }

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = totalFires;
    }
}

void Hook_ShotCandidateLink(void* statePtr, void* candidateMeta, void* weaponData, uint16_t arg4, void* arg5) {
    const uint32_t calls = s_shotCandidateLinkCalls.fetch_add(1, std::memory_order_relaxed) + 1;
    const uint32_t totalFires = s_fires.fetch_add(1, std::memory_order_relaxed) + 1;

    uint32_t before[12]{};
    uint32_t after[12]{};
    const bool beforeOk = ReadU32Words(candidateMeta, 0, before, 12);

    if (!s_originalShotCandidateLink) {
        LogError("[HeadTrackingAim] shot-link +0x291F58C missing original function");
        return;
    }

    s_originalShotCandidateLink(statePtr, candidateMeta, weaponData, arg4, arg5);

    const bool afterOk = ReadU32Words(candidateMeta, 0, after, 12);
    if (!beforeOk || !afterOk) {
        s_shotCandidateLinkFaults.fetch_add(1, std::memory_order_relaxed);
    }

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    const uint64_t nowMs = GetTickCount64();
    const bool inShotVectorWindow = UpdateShotVectorWindow(state, nowMs);
    const bool logShotWindow = inShotVectorWindow && ConsumeShotVectorLogBudget();
    const uint64_t openedAt = s_shotVectorWindowMs.load(std::memory_order_acquire);
    const unsigned long long windowAge = (inShotVectorWindow && nowMs >= openedAt)
        ? static_cast<unsigned long long>(nowMs - openedAt)
        : 0ull;

    if (logShotWindow || (calls <= 8 && state.applied_frame > 0)) {
        LogInfo("[HeadTrackingAim] shot-link +0x291F58C #%u total=%u state=%p meta=%p weapon_data=%p arg4=%u arg5=%p before_ok=%d after_ok=%d before=[%08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X] after=[%08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X %08X] enabled=%d applied=%u yaw=%.2f pitch=%.2f req=%u shot_seq=%u ack=%u window=%d window_age_ms=%llu",
                calls,
                totalFires,
                statePtr,
                candidateMeta,
                weaponData,
                static_cast<unsigned int>(arg4),
                arg5,
                beforeOk ? 1 : 0,
                afterOk ? 1 : 0,
                before[0],
                before[1],
                before[2],
                before[3],
                before[4],
                before[5],
                before[6],
                before[7],
                before[8],
                before[9],
                before[10],
                before[11],
                after[0],
                after[1],
                after[2],
                after[3],
                after[4],
                after[5],
                after[6],
                after[7],
                after[8],
                after[9],
                after[10],
                after[11],
                state.enabled ? 1 : 0,
                state.applied_frame,
                state.yaw,
                state.pitch,
                state.restore_req_seq,
                state.shot_marker_seq,
                state.restore_ack_seq,
                inShotVectorWindow ? 1 : 0,
                windowAge);
    }

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = totalFires;
    }
}

struct ShotCandidateGateSnapshot {
    uint32_t meta[8];
    uint32_t arg3[16];
    uint32_t slot[8];
    uint32_t out0[8];
    uint32_t out30[8];
    uint32_t vec[4];
    Vec4 vecFloat;
    Vec3 vecFixed;
    Vec4 out0Float;
    Vec4 out30Float;
    uint16_t metaSlot;
    uint8_t metaKind;
    uint32_t metaCount;
    bool metaOk;
    bool arg3Ok;
    bool slotOk;
    bool out0Ok;
    bool out30Ok;
    bool vecOk;
    bool vecFloatOk;
    bool vecFixedOk;
    bool out0FloatOk;
    bool out30FloatOk;
};

bool ReadShotCandidateGateSnapshot(void* candidateMeta,
                                   void* arg3,
                                   void* weaponSlot,
                                   void* candidateOut,
                                   void* vectorOut,
                                   ShotCandidateGateSnapshot& snapshot) {
    snapshot = {};
    snapshot.metaOk = ReadU32Words(candidateMeta, 0, snapshot.meta, 8);
    snapshot.arg3Ok = ReadU32Words(arg3, 0, snapshot.arg3, 16);
    snapshot.slotOk = ReadU32Words(weaponSlot, 0, snapshot.slot, 8);
    snapshot.out0Ok = ReadU32Words(candidateOut, 0, snapshot.out0, 8);
    snapshot.out30Ok = ReadU32Words(candidateOut, 0x30, snapshot.out30, 8);
    snapshot.vecOk = ReadU32Words(vectorOut, 0, snapshot.vec, 4);
    snapshot.vecFloatOk = ReadVec4At(vectorOut, 0, snapshot.vecFloat);
    snapshot.vecFixedOk = ReadFixedVec3At(vectorOut, 0, snapshot.vecFixed);
    snapshot.out0FloatOk = ReadVec4At(candidateOut, 0, snapshot.out0Float);
    snapshot.out30FloatOk = ReadVec4At(candidateOut, 0x30, snapshot.out30Float);

    if (candidateMeta) {
        __try {
            const uint8_t* bytes = reinterpret_cast<const uint8_t*>(candidateMeta);
            snapshot.metaSlot = *reinterpret_cast<const uint16_t*>(bytes + 0x0a);
            snapshot.metaKind = bytes[0x12];
            snapshot.metaCount = *reinterpret_cast<const uint32_t*>(bytes + 0x14);
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            snapshot.metaOk = false;
        }
    }

    return snapshot.metaOk ||
           snapshot.arg3Ok ||
           snapshot.slotOk ||
           snapshot.out0Ok ||
           snapshot.out30Ok ||
           snapshot.vecOk ||
           snapshot.vecFloatOk ||
           snapshot.vecFixedOk ||
           snapshot.out0FloatOk ||
           snapshot.out30FloatOk;
}

uint8_t Hook_ShotCandidateGate(void* statePtr,
                               void* candidateMeta,
                               void* arg3,
                               void* weaponSlot,
                               uint64_t weaponSlotPayload,
                               void* candidateOut,
                               void* vectorOut) {
    const uint32_t calls = s_shotCandidateGateCalls.fetch_add(1, std::memory_order_relaxed) + 1;
    const uint32_t totalFires = s_fires.fetch_add(1, std::memory_order_relaxed) + 1;

    ShotCandidateGateSnapshot before{};
    const bool beforeOk = ReadShotCandidateGateSnapshot(candidateMeta,
                                                        arg3,
                                                        weaponSlot,
                                                        candidateOut,
                                                        vectorOut,
                                                        before);

    if (!s_originalShotCandidateGate) {
        LogError("[HeadTrackingAim] shot-gate +0x291FEE0 missing original function");
        return 0;
    }

    const uint8_t result = s_originalShotCandidateGate(statePtr,
                                                       candidateMeta,
                                                       arg3,
                                                       weaponSlot,
                                                       weaponSlotPayload,
                                                       candidateOut,
                                                       vectorOut);

    ShotCandidateGateSnapshot after{};
    const bool afterOk = ReadShotCandidateGateSnapshot(candidateMeta,
                                                       arg3,
                                                       weaponSlot,
                                                       candidateOut,
                                                       vectorOut,
                                                       after);
    if (!beforeOk || !afterOk) {
        s_shotCandidateGateFaults.fetch_add(1, std::memory_order_relaxed);
    }

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    const uint64_t nowMs = GetTickCount64();
    const bool inShotVectorWindow = UpdateShotVectorWindow(state, nowMs);
    const bool logShotWindow = inShotVectorWindow && ConsumeShotVectorLogBudget();
    const uint64_t openedAt = s_shotVectorWindowMs.load(std::memory_order_acquire);
    const unsigned long long windowAge = (inShotVectorWindow && nowMs >= openedAt)
        ? static_cast<unsigned long long>(nowMs - openedAt)
        : 0ull;
    const uintptr_t retAddress = reinterpret_cast<uintptr_t>(_ReturnAddress());
    const uintptr_t retRva = (s_exeBase != 0 && retAddress >= s_exeBase) ? retAddress - s_exeBase : 0;

    if (logShotWindow || (calls <= 16 && state.applied_frame > 0)) {
        LogInfo("[HeadTrackingAim] shot-gate +0x291FEE0 #%u total=%u result=%u ret=+0x%llX state=%p meta=%p arg3=%p slot=%p slot_payload=0x%llX out=%p vec=%p snap_ok=(%d,%d) ok0=(%d,%d,%d,%d,%d,%d) ok1=(%d,%d,%d,%d,%d,%d) meta_slot=%u meta_kind=%u meta_count=%u enabled=%d applied=%u yaw=%.2f pitch=%.2f req=%u shot_seq=%u click_seq=%u ack=%u window_age_ms=%llu faults=%u",
                calls,
                totalFires,
                static_cast<unsigned int>(result),
                static_cast<unsigned long long>(retRva),
                statePtr,
                candidateMeta,
                arg3,
                weaponSlot,
                static_cast<unsigned long long>(weaponSlotPayload),
                candidateOut,
                vectorOut,
                beforeOk ? 1 : 0,
                afterOk ? 1 : 0,
                before.metaOk ? 1 : 0,
                before.arg3Ok ? 1 : 0,
                before.slotOk ? 1 : 0,
                before.out0Ok ? 1 : 0,
                before.out30Ok ? 1 : 0,
                before.vecOk ? 1 : 0,
                after.metaOk ? 1 : 0,
                after.arg3Ok ? 1 : 0,
                after.slotOk ? 1 : 0,
                after.out0Ok ? 1 : 0,
                after.out30Ok ? 1 : 0,
                after.vecOk ? 1 : 0,
                static_cast<unsigned int>(after.metaSlot),
                static_cast<unsigned int>(after.metaKind),
                after.metaCount,
                state.enabled ? 1 : 0,
                state.applied_frame,
                state.yaw,
                state.pitch,
                state.restore_req_seq,
                state.shot_marker_seq,
                SetLocalOrientationHook_GetClickEdgeSeq(),
                state.restore_ack_seq,
                windowAge,
                s_shotCandidateGateFaults.load(std::memory_order_acquire));
        LogInfo("[HeadTrackingAim] shot-gate-vec +0x291FEE0 #%u vec0=[%08X %08X %08X %08X] vec1=[%08X %08X %08X %08X] vec0f=(%.4f %.4f %.4f %.4f) vec1f=(%.4f %.4f %.4f %.4f) vec0fix=(%.4f %.4f %.4f) vec1fix=(%.4f %.4f %.4f)",
                calls,
                before.vec[0],
                before.vec[1],
                before.vec[2],
                before.vec[3],
                after.vec[0],
                after.vec[1],
                after.vec[2],
                after.vec[3],
                before.vecFloat.x,
                before.vecFloat.y,
                before.vecFloat.z,
                before.vecFloat.w,
                after.vecFloat.x,
                after.vecFloat.y,
                after.vecFloat.z,
                after.vecFloat.w,
                before.vecFixed.x,
                before.vecFixed.y,
                before.vecFixed.z,
                after.vecFixed.x,
                after.vecFixed.y,
                after.vecFixed.z);
        LogInfo("[HeadTrackingAim] shot-gate-data +0x291FEE0 #%u meta1=[%08X %08X %08X %08X %08X %08X %08X %08X] arg3_20=[%08X %08X %08X %08X %08X %08X %08X %08X] slot1=[%08X %08X %08X %08X %08X %08X %08X %08X]",
                calls,
                after.meta[0],
                after.meta[1],
                after.meta[2],
                after.meta[3],
                after.meta[4],
                after.meta[5],
                after.meta[6],
                after.meta[7],
                after.arg3[8],
                after.arg3[9],
                after.arg3[10],
                after.arg3[11],
                after.arg3[12],
                after.arg3[13],
                after.arg3[14],
                after.arg3[15],
                after.slot[0],
                after.slot[1],
                after.slot[2],
                after.slot[3],
                after.slot[4],
                after.slot[5],
                after.slot[6],
                after.slot[7]);
        LogInfo("[HeadTrackingAim] shot-gate-out +0x291FEE0 #%u out0_0=[%08X %08X %08X %08X] out0_1=[%08X %08X %08X %08X] out30_0=[%08X %08X %08X %08X] out30_1=[%08X %08X %08X %08X] out0f1=(%.4f %.4f %.4f %.4f) out30f1=(%.4f %.4f %.4f %.4f)",
                calls,
                before.out0[0],
                before.out0[1],
                before.out0[2],
                before.out0[3],
                after.out0[0],
                after.out0[1],
                after.out0[2],
                after.out0[3],
                before.out30[0],
                before.out30[1],
                before.out30[2],
                before.out30[3],
                after.out30[0],
                after.out30[1],
                after.out30[2],
                after.out30[3],
                after.out0Float.x,
                after.out0Float.y,
                after.out0Float.z,
                after.out0Float.w,
                after.out30Float.x,
                after.out30Float.y,
                after.out30Float.z,
                after.out30Float.w);
    }

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = totalFires;
    }

    return result;
}

void CompensateTraceBasis(void* arg3, void* rayList, const HeadTrackingState& state, SavedVec3* saved, int& savedCount) {
    if (!arg3 || !rayList || !saved) return;

    __try {
        float invHead[4]{};
        if (!ReadQuatInverse(state, invHead)) {
            s_lookupFailed.fetch_add(1, std::memory_order_relaxed);
            return;
        }

        uint8_t* base = reinterpret_cast<uint8_t*>(arg3);
        uint8_t* list = reinterpret_cast<uint8_t*>(rayList);
        Vec3 forward = Normalize(*reinterpret_cast<Vec3*>(base + 0x40));
        Vec3 right = Normalize(*reinterpret_cast<Vec3*>(base + 0x50));
        Vec3 up = Normalize(*reinterpret_cast<Vec3*>(base + 0x60));
        Vec3 segment = *reinterpret_cast<Vec3*>(list + 0x30);
        const float segmentLen = Len(segment);

        if (!IsUnitish(forward.x, forward.y, forward.z) ||
            !IsUnitish(right.x, right.y, right.z) ||
            !IsUnitish(up.x, up.y, up.z) ||
            !std::isfinite(segmentLen) ||
            segmentLen < 0.001f) {
            s_lookupFailed.fetch_add(1, std::memory_order_relaxed);
            return;
        }

        const Vec3 cleanForward = Normalize(WorldFromLocal(RotateLocalByQuat(invHead, {0.0f, 1.0f, 0.0f}), right, forward, up));
        const Vec3 cleanRight = Normalize(WorldFromLocal(RotateLocalByQuat(invHead, {1.0f, 0.0f, 0.0f}), right, forward, up));
        const Vec3 cleanUp = Normalize(WorldFromLocal(RotateLocalByQuat(invHead, {0.0f, 0.0f, 1.0f}), right, forward, up));
        const Vec3 cleanSegment = Scale(cleanForward, segmentLen);

        SaveAndWrite(reinterpret_cast<float*>(base + 0x40), cleanForward, saved, savedCount);
        SaveAndWrite(reinterpret_cast<float*>(base + 0x50), cleanRight, saved, savedCount);
        SaveAndWrite(reinterpret_cast<float*>(base + 0x60), cleanUp, saved, savedCount);
        SaveAndWrite(reinterpret_cast<float*>(base + 0x70), cleanForward, saved, savedCount);
        SaveAndWrite(reinterpret_cast<float*>(base + 0xC0), cleanRight, saved, savedCount);
        SaveAndWrite(reinterpret_cast<float*>(base + 0xD0), cleanUp, saved, savedCount);
        SaveAndWrite(reinterpret_cast<float*>(base + 0xE0), cleanForward, saved, savedCount);
        SaveAndWrite(reinterpret_cast<float*>(list + 0x30), cleanSegment, saved, savedCount);

        uint8_t* entries = *reinterpret_cast<uint8_t**>(list);
        const uint32_t count = *reinterpret_cast<uint32_t*>(list + 0x0C);
        if (entries && count > 0 && count <= 64) {
            s_entriesSeen.fetch_add(count, std::memory_order_relaxed);
            for (uint32_t i = 0; i < count && savedCount + 3 <= kMaxSavedVecs; ++i) {
                uint8_t* entry = entries + static_cast<size_t>(i) * 0x70;
                SaveAndWrite(reinterpret_cast<float*>(entry + 0x00), cleanRight, saved, savedCount);
                SaveAndWrite(reinterpret_cast<float*>(entry + 0x10), cleanUp, saved, savedCount);
                SaveAndWrite(reinterpret_cast<float*>(entry + 0x20), cleanForward, saved, savedCount);
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_lookupFailed.fetch_add(1, std::memory_order_relaxed);
    }
}

void RotateArg3Transform(void* arg3, float yaw, float pitch, SavedVec3* saved, int& savedCount) {
    if (!arg3 || !saved) return;

    __try {
        uint8_t* base = reinterpret_cast<uint8_t*>(arg3);
        const uint32_t offsets[] = {
            0x40, 0x50, 0x60,
            0x70,
            0xC0, 0xD0, 0xE0
        };
        for (uint32_t offset : offsets) {
            RotateAndSave(reinterpret_cast<float*>(base + offset), yaw, pitch, saved, savedCount);
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_lookupFailed.fetch_add(1, std::memory_order_relaxed);
    }
}

void RotateRayListHeader(void* rayList, float yaw, float pitch, SavedVec3* saved, int& savedCount) {
    if (!rayList || !saved) return;

    __try {
        uint8_t* list = reinterpret_cast<uint8_t*>(rayList);
        RotateAndSaveDisplacement(reinterpret_cast<float*>(list + 0x30), yaw, pitch, saved, savedCount);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_lookupFailed.fetch_add(1, std::memory_order_relaxed);
    }
}

void RotateRayEntries(void* rayList, float yaw, float pitch, SavedVec3* saved, int& savedCount) {
    if (!rayList || !saved) return;

    __try {
        uint8_t* list = reinterpret_cast<uint8_t*>(rayList);
        uint8_t* entries = *reinterpret_cast<uint8_t**>(list);
        const uint32_t count = *reinterpret_cast<uint32_t*>(list + 0x0C);

        if (!entries || count == 0 || count > 64) return;
        s_entriesSeen.fetch_add(count, std::memory_order_relaxed);

        for (uint32_t i = 0; i < count && savedCount + 3 <= kMaxSavedVecs; ++i) {
            uint8_t* entry = entries + static_cast<size_t>(i) * 0x70;
            RotateAndSave(reinterpret_cast<float*>(entry + 0x00), yaw, pitch, saved, savedCount);
            RotateAndSave(reinterpret_cast<float*>(entry + 0x10), yaw, pitch, saved, savedCount);
            RotateAndSave(reinterpret_cast<float*>(entry + 0x20), yaw, pitch, saved, savedCount);
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_lookupFailed.fetch_add(1, std::memory_order_relaxed);
    }
}

void RestoreSaved(SavedVec3* saved, int savedCount) {
    if (!saved || savedCount <= 0) return;

    __try {
        for (int i = 0; i < savedCount; ++i) {
            if (!saved[i].ptr) continue;
            saved[i].ptr[0] = saved[i].x;
            saved[i].ptr[1] = saved[i].y;
            saved[i].ptr[2] = saved[i].z;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_lookupFailed.fetch_add(1, std::memory_order_relaxed);
    }
}

bool IsVelocityish(float x, float y, float z) {
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) return false;
    const float mag2 = x * x + y * y + z * z;
    return mag2 >= 100.0f && mag2 <= 100000000.0f;
}

bool RotateCandidateRow(float* v,
                        float yaw,
                        float pitch,
                        SavedVec3* saved,
                        int& savedCount,
                        bool allowVelocity) {
    if (!v || !saved || savedCount >= kMaxSavedVecs) return false;

    const float x = v[0];
    const float y = v[1];
    const float z = v[2];
    if (!IsUnitish(x, y, z) && !(allowVelocity && IsVelocityish(x, y, z))) {
        return false;
    }

    saved[savedCount] = { v, x, y, z };
    ++savedCount;

    float rx = x;
    float ry = y;
    float rz = z;
    RotateVector(rx, ry, rz, yaw, pitch);
    v[0] = rx;
    v[1] = ry;
    v[2] = rz;
    return true;
}

int RotateCandidateRows(void* ptr,
                        size_t bytes,
                        float yaw,
                        float pitch,
                        SavedVec3* saved,
                        int& savedCount,
                        bool allowVelocity) {
    if (!ptr || !saved) return 0;

    int changed = 0;
    uint8_t* p = reinterpret_cast<uint8_t*>(ptr);
    for (size_t offset = 0; offset + 12 <= bytes && savedCount < kMaxSavedVecs; offset += 16) {
        if (RotateCandidateRow(reinterpret_cast<float*>(p + offset), yaw, pitch, saved, savedCount, allowVelocity)) {
            ++changed;
        }
    }
    return changed;
}

int MutateShotCandidateBSource(void* rdxArg,
                               const HeadTrackingState& state,
                               SavedVec3* saved,
                               int& savedCount,
                               void** sourceRootOut,
                               void** sourceOut) {
    if (sourceRootOut) *sourceRootOut = nullptr;
    if (sourceOut) *sourceOut = nullptr;
    if (!rdxArg || !saved) return 0;

    __try {
        void* sourceRoot = *reinterpret_cast<void**>(reinterpret_cast<uint8_t*>(rdxArg) + 0xD8);
        void* source = sourceRoot ? reinterpret_cast<uint8_t*>(sourceRoot) + 0x140 : nullptr;
        if (sourceRootOut) *sourceRootOut = sourceRoot;
        if (sourceOut) *sourceOut = source;

        const float yaw = -state.yaw;
        const float pitch = -state.pitch;
        int changed = 0;

        changed += RotateCandidateRows(source, 0x240, yaw, pitch, saved, savedCount, false);

        uint8_t* rdx = reinterpret_cast<uint8_t*>(rdxArg);
        if (RotateCandidateRow(reinterpret_cast<float*>(rdx + 0xF0), yaw, pitch, saved, savedCount, false)) ++changed;
        if (RotateCandidateRow(reinterpret_cast<float*>(rdx + 0x100), yaw, pitch, saved, savedCount, true)) ++changed;
        if (RotateCandidateRow(reinterpret_cast<float*>(rdx + 0x110), yaw, pitch, saved, savedCount, false)) ++changed;

        return changed;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_shotOrchestratorFaults.fetch_add(1, std::memory_order_relaxed);
        return 0;
    }
}

uintptr_t Hook_TargetHelper(void* arg1, void* outHit, void* shotContext, void* targetInfo, float* origin, float* target) {
    const uint32_t fires = s_targetHelperFires.fetch_add(1, std::memory_order_relaxed) + 1;
    s_fires.fetch_add(1, std::memory_order_relaxed);

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    const uintptr_t retAddr = reinterpret_cast<uintptr_t>(_ReturnAddress());
    const uintptr_t shotRet = s_exeBase + kTargetHelperShotReturnOffset;
    const bool fromShotWrapper = retAddr == shotRet;
    const bool hasPose =
        state.enabled &&
        state.applied_frame > 0 &&
        (std::fabs(state.yaw) >= 0.1f || std::fabs(state.pitch) >= 0.1f);

    bool mutated = false;
    Vec4 oldTarget{};
    Vec4 newTarget{};

    if (fromShotWrapper && hasPose && origin && target) {
        __try {
            oldTarget = {target[0], target[1], target[2], target[3]};

            float dx = target[0] - origin[0];
            float dy = target[1] - origin[1];
            float dz = target[2] - origin[2];
            const float lenSq = dx * dx + dy * dy + dz * dz;
            if (std::isfinite(lenSq) && lenSq > 0.0001f) {
                RotateVector(dx, dy, dz, -state.yaw, -state.pitch);
                target[0] = origin[0] + dx;
                target[1] = origin[1] + dy;
                target[2] = origin[2] + dz;
                newTarget = {target[0], target[1], target[2], target[3]};
                mutated = true;
                s_targetHelperMutated.fetch_add(1, std::memory_order_relaxed);
            } else {
                s_targetHelperSkipped.fetch_add(1, std::memory_order_relaxed);
            }
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            s_targetHelperFaults.fetch_add(1, std::memory_order_relaxed);
        }
    } else {
        s_targetHelperSkipped.fetch_add(1, std::memory_order_relaxed);
    }

    if (fires <= 12) {
        const uintptr_t retRva = (s_exeBase != 0 && retAddr >= s_exeBase) ? (retAddr - s_exeBase) : 0;
        LogInfo("[HeadTrackingAim] target-helper #%u ret=+0x%llX from_shot=%d mutated=%d yaw=%.2f pitch=%.2f origin=%p target=%p old=(%.2f,%.2f,%.2f) new=(%.2f,%.2f,%.2f)",
                fires,
                static_cast<unsigned long long>(retRva),
                fromShotWrapper ? 1 : 0,
                mutated ? 1 : 0,
                state.yaw,
                state.pitch,
                origin,
                target,
                oldTarget.x,
                oldTarget.y,
                oldTarget.z,
                newTarget.x,
                newTarget.y,
                newTarget.z);
    }

    if (!s_originalTargetHelper) {
        LogError("[HeadTrackingAim] target-helper hook missing original function");
        return 0;
    }

    const uintptr_t result = s_originalTargetHelper(arg1, outHit, shotContext, targetInfo, origin, target);

    if (mutated) {
        __try {
            target[0] = oldTarget.x;
            target[1] = oldTarget.y;
            target[2] = oldTarget.z;
            target[3] = oldTarget.w;
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            s_targetHelperFaults.fetch_add(1, std::memory_order_relaxed);
        }
    }

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = fires;
    }

    const uint64_t nowMs = GetTickCount64();
    if (s_lastHeartbeatMs == 0 || nowMs - s_lastHeartbeatMs > 3000) {
        LogInfo("[HeadTrackingAim] target-helper hook heartbeat: fires=%u active=%d mutated=%u skipped=%u faults=%u yaw=%.2f pitch=%.2f",
                fires,
                HitscanHook_IsActive() ? 1 : 0,
                s_targetHelperMutated.load(std::memory_order_relaxed),
                s_targetHelperSkipped.load(std::memory_order_relaxed),
                s_targetHelperFaults.load(std::memory_order_relaxed),
                state.yaw,
                state.pitch);
        s_lastHeartbeatMs = nowMs;
    }

    return result;
}

void* Hook_Normalize(float* input, float* output) {
    const uintptr_t retAddr = reinterpret_cast<uintptr_t>(_ReturnAddress());
    const bool fromShotVector = retAddr == s_exeBase + kNormalizeShotReturnOffset;

    if (!fromShotVector) {
        return s_originalNormalize ? s_originalNormalize(input, output) : nullptr;
    }

    const uint32_t fires = s_normalizeFires.fetch_add(1, std::memory_order_relaxed) + 1;
    s_fires.fetch_add(1, std::memory_order_relaxed);

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    const bool hasPose =
        state.enabled &&
        state.applied_frame > 0 &&
        (std::fabs(state.yaw) >= 0.1f || std::fabs(state.pitch) >= 0.1f);

    bool mutated = false;
    Vec4 oldInput{};
    Vec4 newInput{};

    if (input) {
        __try {
            oldInput = {input[0], input[1], input[2], input[3]};
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            s_normalizeFaults.fetch_add(1, std::memory_order_relaxed);
        }
    }

    if (kMutateNormalizeVector && hasPose && input) {
        __try {
            float x = input[0];
            float y = input[1];
            float z = input[2];
            const float lenSq = x * x + y * y + z * z;
            if (std::isfinite(lenSq) && lenSq > 0.0001f) {
                RotateVector(x, y, z, state.yaw, -state.pitch);
                input[0] = x;
                input[1] = y;
                input[2] = z;
                newInput = {input[0], input[1], input[2], input[3]};
                mutated = true;
                s_normalizeMutated.fetch_add(1, std::memory_order_relaxed);
            } else {
                s_normalizeSkipped.fetch_add(1, std::memory_order_relaxed);
            }
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            s_normalizeFaults.fetch_add(1, std::memory_order_relaxed);
        }
    } else {
        s_normalizeSkipped.fetch_add(1, std::memory_order_relaxed);
    }

    void* result = nullptr;
    if (s_originalNormalize) {
        result = s_originalNormalize(input, output);
    } else {
        LogError("[HeadTrackingAim] normalize hook missing original function");
    }

    Vec4 outVec{};
    if (output) {
        __try {
            outVec = {output[0], output[1], output[2], output[3]};
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            s_normalizeFaults.fetch_add(1, std::memory_order_relaxed);
        }
    }

    if (mutated) {
        __try {
            input[0] = oldInput.x;
            input[1] = oldInput.y;
            input[2] = oldInput.z;
            input[3] = oldInput.w;
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            s_normalizeFaults.fetch_add(1, std::memory_order_relaxed);
        }
    }

    bool restored = false;
    if (kRestoreSnapCleanAtNormalizeCallsite &&
        state.pending_native_restore &&
        state.restore_req_seq != 0) {
        restored = NativeCamRestore_DirectWrite(state.restore_quat_i,
                                                state.restore_quat_j,
                                                state.restore_quat_k,
                                                state.restore_quat_r);
        if (restored) {
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                if (w->restore_req_seq == state.restore_req_seq) {
                    w->pending_native_restore = false;
                    w->restore_ack_seq = state.restore_req_seq;
                    w->restore_fires = w->restore_fires + 1;
                }
            }
        }
    }

    if (fires <= 12) {
        LogInfo("[HeadTrackingAim] normalize-shot #%u mutated=%d restored=%d pending=%d yaw=%.2f pitch=%.2f in_old=(%.2f,%.2f,%.2f) in_new=(%.2f,%.2f,%.2f) out=(%.4f,%.4f,%.4f)",
                fires,
                mutated ? 1 : 0,
                restored ? 1 : 0,
                state.pending_native_restore ? 1 : 0,
                state.yaw,
                state.pitch,
                oldInput.x,
                oldInput.y,
                oldInput.z,
                newInput.x,
                newInput.y,
                newInput.z,
                outVec.x,
                outVec.y,
                outVec.z);
    }

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = fires;
    }

    const uint64_t nowMs = GetTickCount64();
    if (s_lastHeartbeatMs == 0 || nowMs - s_lastHeartbeatMs > 3000) {
        LogInfo("[HeadTrackingAim] normalize hook heartbeat: fires=%u active=%d mutated=%u skipped=%u faults=%u yaw=%.2f pitch=%.2f",
                fires,
                HitscanHook_IsActive() ? 1 : 0,
                s_normalizeMutated.load(std::memory_order_relaxed),
                s_normalizeSkipped.load(std::memory_order_relaxed),
                s_normalizeFaults.load(std::memory_order_relaxed),
                state.yaw,
                state.pitch);
        s_lastHeartbeatMs = nowMs;
    }

    return result;
}

void DumpFloatRows(const char* label, void* ptr, size_t bytes) {
    if (!ptr) return;

    __try {
        float* f = reinterpret_cast<float*>(ptr);
        const size_t rows = bytes / 16;
        for (size_t row = 0; row < rows; ++row) {
            const size_t i = row * 4;
            LogInfo("[HeadTrackingAim]   %s+0x%03zX: %+10.4f %+10.4f %+10.4f %+10.4f",
                    label,
                    row * 16,
                    f[i + 0],
                    f[i + 1],
                    f[i + 2],
                    f[i + 3]);
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        LogWarning("[HeadTrackingAim]   %s dump fault", label);
    }
}

void DumpUnitCandidates(const char* label, void* ptr, size_t bytes) {
    if (!ptr) return;

    __try {
        float* f = reinterpret_cast<float*>(ptr);
        const size_t count = bytes / 4;
        int hits = 0;
        for (size_t i = 0; i + 2 < count && hits < 24; ++i) {
            const float x = f[i + 0];
            const float y = f[i + 1];
            const float z = f[i + 2];
            if (!IsUnitish(x, y, z)) continue;
            const float mag = std::sqrt(x * x + y * y + z * z);
            LogInfo("[HeadTrackingAim]   %s unit +0x%03zX: (%+.4f,%+.4f,%+.4f) mag=%.4f",
                    label,
                    i * 4,
                    x,
                    y,
                    z,
                    mag);
            ++hits;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        LogWarning("[HeadTrackingAim]   %s unit scan fault", label);
    }
}

void LogTraceSample(const char* phase,
                    void* arg2,
                    void* arg3,
                    void* rayList,
                    uint32_t fires,
                    const HeadTrackingState& state,
                    int savedCount,
                    uintptr_t result,
                    bool publishedActiveAtEntry) {
    if (!rayList || fires > 8) return;

    __try {
        uint8_t* list = reinterpret_cast<uint8_t*>(rayList);
        uint8_t* entries = *reinterpret_cast<uint8_t**>(list);
        const uint32_t count = *reinterpret_cast<uint32_t*>(list + 0x0C);
        LogInfo("[HeadTrackingAim] physics-call %s dump #%u: arg2=%p arg3=%p rayList=%p entries=%p count=%u result=0x%llX saved_vecs=%d mutate=%d published_active=%d pending_restore=%d yaw=%.2f pitch=%.2f",
                phase,
                fires,
                arg2,
                arg3,
                rayList,
                entries,
                count,
                static_cast<unsigned long long>(result),
                savedCount,
                kEnablePhysicsMutation ? 1 : 0,
                publishedActiveAtEntry ? 1 : 0,
                state.pending_native_restore ? 1 : 0,
                state.yaw,
                state.pitch);

        DumpFloatRows("arg2", arg2, 0x120);
        DumpUnitCandidates("arg2", arg2, 0x180);
        DumpFloatRows("arg3", arg3, 0x120);
        DumpUnitCandidates("arg3", arg3, 0x180);
        DumpFloatRows("rayList", rayList, 0x60);
        DumpUnitCandidates("rayList", rayList, 0x80);

        if (!entries || count == 0 || count > 8) return;
        for (uint32_t i = 0; i < count && i < 3; ++i) {
            char label[32]{};
            std::snprintf(label, sizeof(label), "entry[%u]", i);
            void* entry = entries + static_cast<size_t>(i) * 0x70;
            DumpFloatRows(label, entry, 0x70);
            DumpUnitCandidates(label, entry, 0x70);
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        LogWarning("[HeadTrackingAim] physics-call %s sample fault on fire #%u", phase, fires);
    }
}

const char* TraceModeName(int mode) {
    if (mode == 1) return "direction";
    if (mode == 2) return "endpoint";
    return "none";
}

bool TryCompensateTraceDispatchInput(void* traceInput,
                                     const HeadTrackingState& state,
                                     SavedVec3* saved,
                                     int& savedCount,
                                     int& mode) {
    mode = 0;
    if (!traceInput || !saved) return false;

    __try {
        uint8_t* p = reinterpret_cast<uint8_t*>(traceInput);
        Vec3 a = *reinterpret_cast<Vec3*>(p + 0x08);
        Vec3 b = *reinterpret_cast<Vec3*>(p + 0x18);
        const float aLen = Len(a);
        const float bLen = Len(b);

        if (!std::isfinite(aLen) || !std::isfinite(bLen)) {
            s_traceDispatchSkipped.fetch_add(1, std::memory_order_relaxed);
            return false;
        }

        if (IsUnitish(b.x, b.y, b.z) && aLen > 5.0f) {
            float x = b.x;
            float y = b.y;
            float z = b.z;
            RotateVector(x, y, z, -state.yaw, -state.pitch);
            const Vec3 cleanDir = Normalize({x, y, z});
            mode = 1;
            return SaveAndWrite(reinterpret_cast<float*>(p + 0x18), cleanDir, saved, savedCount);
        }

        Vec3 delta = Sub(b, a);
        const float deltaLen = Len(delta);
        if (!std::isfinite(deltaLen) || deltaLen < 0.1f || deltaLen > 10000.0f) {
            s_traceDispatchSkipped.fetch_add(1, std::memory_order_relaxed);
            return false;
        }

        RotateVector(delta.x, delta.y, delta.z, -state.yaw, -state.pitch);
        mode = 2;
        return SaveAndWrite(reinterpret_cast<float*>(p + 0x18), Add(a, delta), saved, savedCount);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        s_traceDispatchFaults.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
}

void LogTraceDispatchProbe(const char* phase,
                           void* arg1,
                           void* arg2,
                           void* arg3,
                           void* arg4,
                           void* traceInput,
                           void* arg6,
                           uintptr_t retAddr,
                           uint32_t windowCalls,
                           uint32_t totalCalls,
                           const HeadTrackingState& state,
                           int mode,
                           int savedCount,
                           uintptr_t result) {
    if (windowCalls > 16) return;

    __try {
        const uintptr_t retRva = (s_exeBase != 0 && retAddr >= s_exeBase) ? (retAddr - s_exeBase) : 0;
        LogInfo("[HeadTrackingAim] trace-dispatch %s window=%u total=%u ret=+0x%llX args=(%p,%p,%p,%p,%p,%p) mode=%s saved=%d result=0x%llX yaw=%.2f pitch=%.2f pending=%d",
                phase,
                windowCalls,
                totalCalls,
                static_cast<unsigned long long>(retRva),
                arg1,
                arg2,
                arg3,
                arg4,
                traceInput,
                arg6,
                TraceModeName(mode),
                savedCount,
                static_cast<unsigned long long>(result),
                state.yaw,
                state.pitch,
                state.pending_native_restore ? 1 : 0);

        DumpFloatRows("trace.input", traceInput, 0x40);
        DumpUnitCandidates("trace.input", traceInput, 0x40);
        DumpFloatRows("trace.arg1", arg1, 0x80);
        DumpUnitCandidates("trace.arg1", arg1, 0x80);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        LogWarning("[HeadTrackingAim] trace-dispatch %s probe fault on window call #%u",
                   phase,
                   windowCalls);
    }
}

uintptr_t Hook_TraceDispatch(void* arg1, void* arg2, void* arg3, void* arg4, void* traceInput, void* arg6) {
    const uint32_t totalCalls = s_traceDispatchCalls.fetch_add(1, std::memory_order_relaxed) + 1;
    const uintptr_t retAddr = reinterpret_cast<uintptr_t>(_ReturnAddress());

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    const bool inShotWindow = !kTraceDispatchRequireShotWindow || state.pending_native_restore;
    const bool hasPose =
        state.enabled &&
        state.applied_frame > 0 &&
        (std::fabs(state.yaw) >= 0.1f || std::fabs(state.pitch) >= 0.1f);

    SavedVec3 saved[kMaxSavedVecs]{};
    int savedCount = 0;
    int mode = 0;
    bool mutated = false;
    uint32_t windowCalls = s_traceDispatchWindowCalls.load(std::memory_order_relaxed);

    if (inShotWindow) {
        windowCalls = s_traceDispatchWindowCalls.fetch_add(1, std::memory_order_relaxed) + 1;
        if (kMutateTraceDispatchRay && hasPose) {
            mutated = TryCompensateTraceDispatchInput(traceInput, state, saved, savedCount, mode);
            if (mutated) {
                s_traceDispatchMutated.fetch_add(1, std::memory_order_relaxed);
                s_compensated.fetch_add(1, std::memory_order_relaxed);
            }
        }
        LogTraceDispatchProbe("pre", arg1, arg2, arg3, arg4, traceInput, arg6,
                              retAddr, windowCalls, totalCalls, state, mode, savedCount, 0);
    }

    if (!s_originalTraceDispatch) {
        LogError("[HeadTrackingAim] trace-dispatch hook missing original function");
        RestoreSaved(saved, savedCount);
        return 0;
    }

    const uintptr_t result = s_originalTraceDispatch(arg1, arg2, arg3, arg4, traceInput, arg6);

    if (inShotWindow) {
        LogTraceDispatchProbe("post", arg1, arg2, arg3, arg4, traceInput, arg6,
                              retAddr, windowCalls, totalCalls, state, mode, savedCount, result);
    }
    if (mutated) {
        RestoreSaved(saved, savedCount);
    }

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = totalCalls;
    }

    const uint64_t nowMs = GetTickCount64();
    if (s_lastHeartbeatMs == 0 || nowMs - s_lastHeartbeatMs > 3000) {
        LogInfo("[HeadTrackingAim] trace-dispatch heartbeat: total=%u window=%u mutated=%u skipped=%u faults=%u active=%d yaw=%.2f pitch=%.2f",
                totalCalls,
                s_traceDispatchWindowCalls.load(std::memory_order_relaxed),
                s_traceDispatchMutated.load(std::memory_order_relaxed),
                s_traceDispatchSkipped.load(std::memory_order_relaxed),
                s_traceDispatchFaults.load(std::memory_order_relaxed),
                HitscanHook_IsActive() ? 1 : 0,
                state.yaw,
                state.pitch);
        s_lastHeartbeatMs = nowMs;
    }

    return result;
}

void LogRayDispatchProbe(const char* phase,
                         void* self,
                         void* outResult,
                         void* arg3,
                         void* arg4,
                         uint32_t fires,
                         const HeadTrackingState& state,
                         uintptr_t result) {
    if (fires > 12) return;

    __try {
        uint8_t* selfBytes = reinterpret_cast<uint8_t*>(self);
        const uint32_t count8 = selfBytes ? *reinterpret_cast<uint32_t*>(selfBytes + 0x08) : 0;
        const uint32_t countC = selfBytes ? *reinterpret_cast<uint32_t*>(selfBytes + 0x0C) : 0;
        uint8_t* array = selfBytes ? *reinterpret_cast<uint8_t**>(selfBytes + 0x10) : nullptr;
        uint8_t* ray = array ? array + 0x10 : nullptr;

        LogInfo("[HeadTrackingAim] ray-dispatch %s #%u: self=%p out=%p arg3=%p arg4=%p count8=%u countC=%u array=%p ray=%p result=0x%llX pending_restore=%d yaw=%.2f pitch=%.2f",
                phase,
                fires,
                self,
                outResult,
                arg3,
                arg4,
                count8,
                countC,
                array,
                ray,
                static_cast<unsigned long long>(result),
                state.pending_native_restore ? 1 : 0,
                state.yaw,
                state.pitch);

        DumpFloatRows("raySelf", self, 0x60);
        DumpUnitCandidates("raySelf", self, 0x80);
        DumpFloatRows("rayArray+0x10", ray, 0x80);
        DumpUnitCandidates("rayArray+0x10", ray, 0x80);
        DumpFloatRows("rayOut", outResult, 0x80);
        DumpUnitCandidates("rayOut", outResult, 0x80);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        LogWarning("[HeadTrackingAim] ray-dispatch %s probe fault on fire #%u", phase, fires);
    }
}

uintptr_t Hook_RayDispatch(void* self, void* outResult, void* arg3, void* arg4) {
    const uint32_t fires = s_fires.fetch_add(1, std::memory_order_relaxed) + 1;

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    LogRayDispatchProbe("pre", self, outResult, arg3, arg4, fires, state, 0);

    if (!s_originalRayDispatch) {
        LogError("[HeadTrackingAim] ray-dispatch probe missing original function");
        return 0;
    }

    const uintptr_t result = s_originalRayDispatch(self, outResult, arg3, arg4);

    LogRayDispatchProbe("post", self, outResult, arg3, arg4, fires, state, result);

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = false;
        w->hitscan_hook_fires = fires;
    }

    const uint64_t nowMs = GetTickCount64();
    if (s_lastHeartbeatMs == 0 || nowMs - s_lastHeartbeatMs > 3000) {
        LogInfo("[HeadTrackingAim] ray-dispatch probe heartbeat: fires=%u pending_restore=%d yaw=%.2f pitch=%.2f",
                fires,
                state.pending_native_restore ? 1 : 0,
                state.yaw,
                state.pitch);
        s_lastHeartbeatMs = nowMs;
    }

    return result;
}

void LogShotCandidateProbe(const char* name,
                           const char* phase,
                           void* rcxArg,
                           void* rdxArg,
                           void* r8Arg,
                           void* r9Arg,
                           uint32_t fires,
                           uint32_t totalFires,
                           const HeadTrackingState& state,
                           uintptr_t result) {
    if (!state.pending_native_restore || fires > 12) return;

    __try {
        void* rdx0 = rdxArg ? *reinterpret_cast<void**>(rdxArg) : nullptr;
        void* rdxD8 = rdxArg ? *reinterpret_cast<void**>(reinterpret_cast<uint8_t*>(rdxArg) + 0xD8) : nullptr;
        void* rdxSource = rdxD8 ? reinterpret_cast<uint8_t*>(rdxD8) + 0x140 : nullptr;
        void* r80 = r8Arg ? *reinterpret_cast<void**>(r8Arg) : nullptr;
        void* r8d8 = r8Arg ? *reinterpret_cast<void**>(reinterpret_cast<uint8_t*>(r8Arg) + 0xD8) : nullptr;

        LogInfo("[HeadTrackingAim] shot-probe %s %s #%u total=%u: rcx=%p rdx=%p r8=%p r9=%p rdx0=%p rdxD8=%p source=%p r80=%p r8d8=%p result=0x%llX pending_restore=%d yaw=%.2f pitch=%.2f",
                name,
                phase,
                fires,
                totalFires,
                rcxArg,
                rdxArg,
                r8Arg,
                r9Arg,
                rdx0,
                rdxD8,
                rdxSource,
                r80,
                r8d8,
                static_cast<unsigned long long>(result),
                state.pending_native_restore ? 1 : 0,
                state.yaw,
                state.pitch);

        DumpFloatRows("shot.rcx", rcxArg, 0x120);
        DumpUnitCandidates("shot.rcx", rcxArg, 0x180);
        DumpFloatRows("shot.rdx", rdxArg, 0x120);
        DumpUnitCandidates("shot.rdx", rdxArg, 0x180);
        DumpFloatRows("shot.rdx.d8+140", rdxSource, 0x180);
        DumpUnitCandidates("shot.rdx.d8+140", rdxSource, 0x240);
        DumpFloatRows("shot.r8", r8Arg, 0x180);
        DumpUnitCandidates("shot.r8", r8Arg, 0x200);
        DumpFloatRows("shot.rdx0", rdx0, 0x120);
        DumpUnitCandidates("shot.rdx0", rdx0, 0x180);
        DumpFloatRows("shot.r80", r80, 0x120);
        DumpUnitCandidates("shot.r80", r80, 0x180);
        DumpFloatRows("shot.r8d8", r8d8, 0x120);
        DumpUnitCandidates("shot.r8d8", r8d8, 0x180);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        LogWarning("[HeadTrackingAim] shot-probe %s %s fault on fire #%u",
                   name,
                   phase,
                   fires);
    }
}

uintptr_t Hook_ShotCandidateA(void* rcxArg, void* rdxArg, void* r8Arg, void* r9Arg) {
    const uint32_t fires = s_candidateAFires.fetch_add(1, std::memory_order_relaxed) + 1;
    const uint32_t totalFires = s_fires.fetch_add(1, std::memory_order_relaxed) + 1;

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    LogShotCandidateProbe("+0x291D9CC", "pre", rcxArg, rdxArg, r8Arg, r9Arg, fires, totalFires, state, 0);

    if (!s_originalShotCandidateA) {
        LogError("[HeadTrackingAim] shot-probe +0x291D9CC missing original function");
        return 0;
    }

    const uintptr_t result = s_originalShotCandidateA(rcxArg, rdxArg, r8Arg, r9Arg);

    LogShotCandidateProbe("+0x291D9CC", "post", rcxArg, rdxArg, r8Arg, r9Arg, fires, totalFires, state, result);

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = totalFires;
    }

    return result;
}

uintptr_t Hook_ShotCandidateB(void* rcxArg, void* rdxArg, void* r8Arg, void* r9Arg) {
    const uint32_t fires = s_candidateBFires.fetch_add(1, std::memory_order_relaxed) + 1;
    const uint32_t totalFires = s_fires.fetch_add(1, std::memory_order_relaxed) + 1;

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    const bool hasPose =
        state.enabled &&
        state.applied_frame > 0 &&
        (std::fabs(state.yaw) >= 0.1f || std::fabs(state.pitch) >= 0.1f);

    SavedVec3 saved[kMaxSavedVecs]{};
    int savedCount = 0;
    int mutatedRows = 0;
    void* sourceRoot = nullptr;
    void* source = nullptr;

    if (kMutateShotOrchestratorSource && state.pending_native_restore && hasPose) {
        mutatedRows = MutateShotCandidateBSource(rdxArg, state, saved, savedCount, &sourceRoot, &source);
        if (mutatedRows > 0) {
            s_shotOrchestratorMutated.fetch_add(1, std::memory_order_relaxed);
            s_compensated.fetch_add(1, std::memory_order_relaxed);
        } else {
            s_shotOrchestratorSkipped.fetch_add(1, std::memory_order_relaxed);
        }
    } else {
        s_shotOrchestratorSkipped.fetch_add(1, std::memory_order_relaxed);
    }

    if (state.pending_native_restore && fires <= 12) {
        LogInfo("[HeadTrackingAim] shot-B mutate #%u total=%u rows=%d saved=%d sourceRoot=%p source=%p rdx=%p yaw=%.2f pitch=%.2f active=%d pending=%d",
                fires,
                totalFires,
                mutatedRows,
                savedCount,
                sourceRoot,
                source,
                rdxArg,
                state.yaw,
                state.pitch,
                HitscanHook_IsActive() ? 1 : 0,
                state.pending_native_restore ? 1 : 0);
    }

    LogShotCandidateProbe("+0x291DD54", "pre", rcxArg, rdxArg, r8Arg, r9Arg, fires, totalFires, state, 0);

    if (!s_originalShotCandidateB) {
        LogError("[HeadTrackingAim] shot-probe +0x291DD54 missing original function");
        RestoreSaved(saved, savedCount);
        return 0;
    }

    const uintptr_t result = s_originalShotCandidateB(rcxArg, rdxArg, r8Arg, r9Arg);

    LogShotCandidateProbe("+0x291DD54", "post", rcxArg, rdxArg, r8Arg, r9Arg, fires, totalFires, state, result);
    RestoreSaved(saved, savedCount);

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = totalFires;
    }

    return result;
}

bool RestoreStagedCameraAfterShotVector(const HeadTrackingState& state,
                                        const char* label,
                                        uint32_t fires,
                                        uint32_t totalFires) {
    const uint32_t req = state.restore_req_seq;
    if (req == 0) return false;

    const uint32_t staged = g_preRenderPendingSeq.load(std::memory_order_acquire);
    if (staged != req) return false;

    const uint64_t stagedMs = g_preRenderStagedMs.load(std::memory_order_acquire);
    const uint64_t nowMs = GetTickCount64();
    if (stagedMs == 0 || nowMs < stagedMs || nowMs - stagedMs > kShotVectorWindowMs) {
        return false;
    }

    uint32_t observed = s_shotVectorPostRestoreSeq.load(std::memory_order_acquire);
    while (observed != req) {
        if (s_shotVectorPostRestoreSeq.compare_exchange_weak(observed,
                                                             req,
                                                             std::memory_order_acq_rel,
                                                             std::memory_order_acquire)) {
            const float qi = g_preRenderQuat[0];
            const float qj = g_preRenderQuat[1];
            const float qk = g_preRenderQuat[2];
            const float qr = g_preRenderQuat[3];
            const bool restored = NativeCamRestore_DirectWrite(qi, qj, qk, qr);
            if (restored) {
                const uint32_t restores = s_shotVectorPostRestores.fetch_add(1, std::memory_order_relaxed) + 1;
                if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                    if (w->restore_req_seq == req) {
                        w->pending_native_restore = false;
                        w->restore_ack_seq = req;
                        w->restore_fires = w->restore_fires + 1;
                    }
                }
                LogInfo("[HeadTrackingAim] shot-vector post-restore %s #%u total=%u restores=%u req=%u age_ms=%llu quat=(%.3f,%.3f,%.3f,%.3f) pending=%d ack=%u",
                        label,
                        fires,
                        totalFires,
                        restores,
                        req,
                        static_cast<unsigned long long>(nowMs - stagedMs),
                        qi,
                        qj,
                        qk,
                        qr,
                        state.pending_native_restore ? 1 : 0,
                        state.restore_ack_seq);
                return true;
            }

            s_shotVectorPostRestoreSeq.store(0, std::memory_order_release);
            const uint32_t skipped = s_shotVectorPostRestoreSkipped.fetch_add(1, std::memory_order_relaxed) + 1;
            if (skipped <= 8) {
                LogWarning("[HeadTrackingAim] shot-vector post-restore %s failed: req=%u cam=%p off=%d",
                           label,
                           req,
                           reinterpret_cast<void*>(g_camInstance),
                           g_camOrientationOffset);
            }
            return false;
        }
    }

    return false;
}

void Hook_ShotVectorProcessor(void* arg1, void* shotContext, void* shotList) {
    const uint32_t fires = s_shotVectorProcessorCalls.fetch_add(1, std::memory_order_relaxed) + 1;
    const uint32_t totalFires = s_fires.fetch_add(1, std::memory_order_relaxed) + 1;

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    const bool hasPose =
        state.enabled &&
        state.applied_frame > 0 &&
        (std::fabs(state.yaw) >= 0.1f ||
         std::fabs(state.pitch) >= 0.1f ||
         std::fabs(state.roll) >= 0.1f);
    const uint64_t nowMs = GetTickCount64();
    const bool inShotVectorWindow = UpdateShotVectorWindow(state, nowMs);

    SavedFixedVec3 saved{};
    Vec3 before{};
    Vec3 after{};
    Vec3 pivot{};
    void* source = nullptr;
    uint32_t sourceCount = 0;
    bool mutated = false;
    uint32_t mutatedCount = 0;
    uint32_t skipReason = 1;
    uint32_t skippedCount = 0;
    uint32_t pivotKind = 0;
    uint32_t pivotOffset = 0xffffffffu;
    float pivotDistance = 0.0f;
    ShotVectorProbe probe{};
    bool inspected = false;

    if (kMutateShotVectorSource && hasPose && inShotVectorWindow && HasShotVectorMutationBudget()) {
        mutated = MutateShotVectorSource(shotContext, state, saved, before, after, pivot, &source, &sourceCount,
                                         &pivotKind, &pivotOffset, &pivotDistance, &skipReason);
    }

    if (!mutated && inShotVectorWindow) {
        inspected = InspectShotVectorSource(shotContext, probe);
        source = probe.source;
        sourceCount = probe.count;
        before = probe.value;
        after = probe.origin;
        skipReason = probe.reason;
        if (inspected && probe.kind == 2) {
            FindCameraPivotForTarget(before, pivot, pivotKind, pivotOffset, pivotDistance);
        }
    } else if (!mutated) {
        skipReason = hasPose ? 16u : 17u;
    }

    if (mutated) {
        ConsumeShotVectorMutationBudget();
        mutatedCount = s_shotVectorMutated.fetch_add(1, std::memory_order_relaxed) + 1;
        s_compensated.fetch_add(1, std::memory_order_relaxed);
    } else {
        skippedCount = s_shotVectorSkipped.fetch_add(1, std::memory_order_relaxed) + 1;
        if (!hasPose) {
            s_shotVectorNoPose.fetch_add(1, std::memory_order_relaxed);
        }
    }

    const bool logShotWindow = inShotVectorWindow && ConsumeShotVectorLogBudget();
    const uint64_t openedAt = s_shotVectorWindowMs.load(std::memory_order_acquire);
    const unsigned long long windowAge = (inShotVectorWindow && nowMs >= openedAt)
        ? static_cast<unsigned long long>(nowMs - openedAt)
        : 0ull;

    if (logShotWindow ||
        (state.pending_native_restore && fires <= 16) ||
        (mutated && mutatedCount <= 32) ||
        (!mutated && skippedCount <= 32 && state.applied_frame > 0)) {
        LogInfo("[HeadTrackingAim] shot-vector +0x292263C #%u total=%u mutated=%d inspected=%d reason=%u ctx=%p list=%p holder=%p entries=%p source=%p count=%u index=%u kind=%u value=(%.4f %.4f %.4f) new=(%.4f %.4f %.4f) src_origin=(%.4f %.4f %.4f) dist=%.2f pivot_kind=%u pivot_off=0x%X pivot=(%.4f %.4f %.4f) pivot_dist=%.2f enabled=%d applied=%u yaw=%.2f pitch=%.2f pending=%d req=%u shot_seq=%u click_seq=%u ack=%u window=%d window_age_ms=%llu mutate_budget=%u",
                fires,
                totalFires,
                mutated ? 1 : 0,
                inspected ? 1 : 0,
                skipReason,
                shotContext,
                shotList,
                probe.holder,
                probe.entries,
                source,
                sourceCount,
                probe.index,
                probe.kind,
                before.x,
                before.y,
                before.z,
                after.x,
                after.y,
                after.z,
                probe.origin.x,
                probe.origin.y,
                probe.origin.z,
                probe.distance,
                pivotKind,
                pivotOffset,
                pivot.x,
                pivot.y,
                pivot.z,
                pivotDistance,
                state.enabled ? 1 : 0,
                state.applied_frame,
                state.yaw,
                state.pitch,
                state.pending_native_restore ? 1 : 0,
                state.restore_req_seq,
                state.shot_marker_seq,
                SetLocalOrientationHook_GetClickEdgeSeq(),
                state.restore_ack_seq,
                inShotVectorWindow ? 1 : 0,
                windowAge,
                s_shotVectorWindowMutateBudget.load(std::memory_order_acquire));
    }

    if (!s_originalShotVectorProcessor) {
        LogError("[HeadTrackingAim] shot-vector +0x292263C missing original function");
        if (kRestoreShotVectorSourceAfterCall) {
            RestoreFixed(saved);
        }
        return;
    }

    s_originalShotVectorProcessor(arg1, shotContext, shotList);
    RestoreStagedCameraAfterShotVector(state, "+0x292263C", fires, totalFires);

    SavedFixedVec3 postSaved{};
    Vec3 postBefore{};
    Vec3 postAfter{};
    Vec3 postPivot{};
    void* postSource = nullptr;
    uint32_t postSourceCount = 0;
    uint32_t postReason = 1;
    uint32_t postPivotKind = 0;
    uint32_t postPivotOffset = 0xffffffffu;
    float postPivotDistance = 0.0f;
    bool postMutated = false;
    uint32_t postMutatedCount = 0;
    if (kMutateShotVectorSourceAfterCall &&
        kMutateShotVectorSource &&
        hasPose &&
        inShotVectorWindow &&
        HasShotVectorMutationBudget()) {
        postMutated = MutateShotVectorSource(shotContext,
                                             state,
                                             postSaved,
                                             postBefore,
                                             postAfter,
                                             postPivot,
                                             &postSource,
                                             &postSourceCount,
                                             &postPivotKind,
                                             &postPivotOffset,
                                             &postPivotDistance,
                                             &postReason);
        if (postMutated) {
            ConsumeShotVectorMutationBudget();
            postMutatedCount = s_shotVectorMutated.fetch_add(1, std::memory_order_relaxed) + 1;
            s_compensated.fetch_add(1, std::memory_order_relaxed);
        }
        if (kRestoreShotVectorSourceAfterCall) {
            RestoreFixed(postSaved);
        }
    }
    if (postMutated && postMutatedCount <= 64) {
        LogInfo("[HeadTrackingAim] shot-vector +0x292263C post #%u total=%u mutated=1 reason=%u source=%p count=%u value=(%.4f %.4f %.4f) new=(%.4f %.4f %.4f) pivot_kind=%u pivot_off=0x%X pivot=(%.4f %.4f %.4f) pivot_dist=%.2f enabled=%d applied=%u yaw=%.2f pitch=%.2f click_seq=%u mutate_budget=%u",
                fires,
                totalFires,
                postReason,
                postSource,
                postSourceCount,
                postBefore.x,
                postBefore.y,
                postBefore.z,
                postAfter.x,
                postAfter.y,
                postAfter.z,
                postPivotKind,
                postPivotOffset,
                postPivot.x,
                postPivot.y,
                postPivot.z,
                postPivotDistance,
                state.enabled ? 1 : 0,
                state.applied_frame,
                state.yaw,
                state.pitch,
                SetLocalOrientationHook_GetClickEdgeSeq(),
                s_shotVectorWindowMutateBudget.load(std::memory_order_acquire));
    }
    if (kRestoreShotVectorSourceAfterCall) {
        RestoreFixed(saved);
    }

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = totalFires;
    }
}

void Hook_ShotVectorAltProcessor(void* arg1, void* shotContext, void* shotList, float arg4, uint32_t arg5) {
    const uint32_t fires = s_shotVectorAltProcessorCalls.fetch_add(1, std::memory_order_relaxed) + 1;
    const uint32_t totalFires = s_fires.fetch_add(1, std::memory_order_relaxed) + 1;

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    const bool hasPose =
        state.enabled &&
        state.applied_frame > 0 &&
        (std::fabs(state.yaw) >= 0.1f ||
         std::fabs(state.pitch) >= 0.1f ||
         std::fabs(state.roll) >= 0.1f);
    const uint64_t nowMs = GetTickCount64();
    const bool inShotVectorWindow = UpdateShotVectorWindow(state, nowMs);

    SavedFixedVec3 saved{};
    Vec3 before{};
    Vec3 after{};
    Vec3 pivot{};
    void* source = nullptr;
    uint32_t sourceCount = 0;
    bool mutated = false;
    uint32_t mutatedCount = 0;
    uint32_t skipReason = 1;
    uint32_t skippedCount = 0;
    uint32_t pivotKind = 0;
    uint32_t pivotOffset = 0xffffffffu;
    float pivotDistance = 0.0f;
    ShotVectorProbe probe{};
    bool inspected = false;

    if (kMutateShotVectorAltSource && hasPose && inShotVectorWindow && HasShotVectorMutationBudget()) {
        mutated = MutateShotVectorSource(shotContext, state, saved, before, after, pivot, &source, &sourceCount,
                                         &pivotKind, &pivotOffset, &pivotDistance, &skipReason);
    }

    if (!mutated && inShotVectorWindow) {
        inspected = InspectShotVectorSource(shotContext, probe);
        source = probe.source;
        sourceCount = probe.count;
        before = probe.value;
        after = probe.origin;
        skipReason = probe.reason;
        if (inspected && probe.kind == 2) {
            FindCameraPivotForTarget(before, pivot, pivotKind, pivotOffset, pivotDistance);
        }
    } else if (!mutated) {
        skipReason = hasPose ? 16u : 17u;
    }

    if (mutated) {
        ConsumeShotVectorMutationBudget();
        mutatedCount = s_shotVectorMutated.fetch_add(1, std::memory_order_relaxed) + 1;
        s_compensated.fetch_add(1, std::memory_order_relaxed);
    } else {
        skippedCount = s_shotVectorSkipped.fetch_add(1, std::memory_order_relaxed) + 1;
        if (!hasPose) {
            s_shotVectorNoPose.fetch_add(1, std::memory_order_relaxed);
        }
    }

    const bool logShotWindow = inShotVectorWindow && ConsumeShotVectorLogBudget();
    const uint64_t openedAt = s_shotVectorWindowMs.load(std::memory_order_acquire);
    const unsigned long long windowAge = (inShotVectorWindow && nowMs >= openedAt)
        ? static_cast<unsigned long long>(nowMs - openedAt)
        : 0ull;

    if (logShotWindow ||
        (state.pending_native_restore && fires <= 16) ||
        (mutated && mutatedCount <= 32) ||
        (!mutated && skippedCount <= 32 && state.applied_frame > 0)) {
        LogInfo("[HeadTrackingAim] shot-vector +0x292317C #%u total=%u mutated=%d inspected=%d reason=%u ctx=%p list=%p holder=%p entries=%p source=%p count=%u index=%u kind=%u value=(%.4f %.4f %.4f) new=(%.4f %.4f %.4f) src_origin=(%.4f %.4f %.4f) dist=%.2f pivot_kind=%u pivot_off=0x%X pivot=(%.4f %.4f %.4f) pivot_dist=%.2f enabled=%d applied=%u yaw=%.2f pitch=%.2f pending=%d req=%u shot_seq=%u click_seq=%u ack=%u window=%d window_age_ms=%llu mutate_budget=%u param5=%u",
                fires,
                totalFires,
                mutated ? 1 : 0,
                inspected ? 1 : 0,
                skipReason,
                shotContext,
                shotList,
                probe.holder,
                probe.entries,
                source,
                sourceCount,
                probe.index,
                probe.kind,
                before.x,
                before.y,
                before.z,
                after.x,
                after.y,
                after.z,
                probe.origin.x,
                probe.origin.y,
                probe.origin.z,
                probe.distance,
                pivotKind,
                pivotOffset,
                pivot.x,
                pivot.y,
                pivot.z,
                pivotDistance,
                state.enabled ? 1 : 0,
                state.applied_frame,
                state.yaw,
                state.pitch,
                state.pending_native_restore ? 1 : 0,
                state.restore_req_seq,
                state.shot_marker_seq,
                SetLocalOrientationHook_GetClickEdgeSeq(),
                state.restore_ack_seq,
                inShotVectorWindow ? 1 : 0,
                windowAge,
                s_shotVectorWindowMutateBudget.load(std::memory_order_acquire),
                arg5);
    }

    if (!s_originalShotVectorAltProcessor) {
        LogError("[HeadTrackingAim] shot-vector +0x292317C missing original function");
        if (kRestoreShotVectorSourceAfterCall) {
            RestoreFixed(saved);
        }
        return;
    }

    s_originalShotVectorAltProcessor(arg1, shotContext, shotList, arg4, arg5);
    RestoreStagedCameraAfterShotVector(state, "+0x292317C", fires, totalFires);

    SavedFixedVec3 postSaved{};
    Vec3 postBefore{};
    Vec3 postAfter{};
    Vec3 postPivot{};
    void* postSource = nullptr;
    uint32_t postSourceCount = 0;
    uint32_t postReason = 1;
    uint32_t postPivotKind = 0;
    uint32_t postPivotOffset = 0xffffffffu;
    float postPivotDistance = 0.0f;
    bool postMutated = false;
    uint32_t postMutatedCount = 0;
    if (kMutateShotVectorSourceAfterCall &&
        kMutateShotVectorAltSource &&
        hasPose &&
        inShotVectorWindow &&
        HasShotVectorMutationBudget()) {
        postMutated = MutateShotVectorSource(shotContext,
                                             state,
                                             postSaved,
                                             postBefore,
                                             postAfter,
                                             postPivot,
                                             &postSource,
                                             &postSourceCount,
                                             &postPivotKind,
                                             &postPivotOffset,
                                             &postPivotDistance,
                                             &postReason);
        if (postMutated) {
            ConsumeShotVectorMutationBudget();
            postMutatedCount = s_shotVectorMutated.fetch_add(1, std::memory_order_relaxed) + 1;
            s_compensated.fetch_add(1, std::memory_order_relaxed);
        }
        if (kRestoreShotVectorSourceAfterCall) {
            RestoreFixed(postSaved);
        }
    }
    if (postMutated && postMutatedCount <= 64) {
        LogInfo("[HeadTrackingAim] shot-vector +0x292317C post #%u total=%u mutated=1 reason=%u source=%p count=%u value=(%.4f %.4f %.4f) new=(%.4f %.4f %.4f) pivot_kind=%u pivot_off=0x%X pivot=(%.4f %.4f %.4f) pivot_dist=%.2f enabled=%d applied=%u yaw=%.2f pitch=%.2f click_seq=%u mutate_budget=%u param5=%u",
                fires,
                totalFires,
                postReason,
                postSource,
                postSourceCount,
                postBefore.x,
                postBefore.y,
                postBefore.z,
                postAfter.x,
                postAfter.y,
                postAfter.z,
                postPivotKind,
                postPivotOffset,
                postPivot.x,
                postPivot.y,
                postPivot.z,
                postPivotDistance,
                state.enabled ? 1 : 0,
                state.applied_frame,
                state.yaw,
                state.pitch,
                SetLocalOrientationHook_GetClickEdgeSeq(),
                s_shotVectorWindowMutateBudget.load(std::memory_order_acquire),
                arg5);
    }
    if (kRestoreShotVectorSourceAfterCall) {
        RestoreFixed(saved);
    }

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = totalFires;
    }
}

PhysicsTraceFn ResolveOriginalPhysicsTrace(void* self) {
    if (!self) return nullptr;

    __try {
        void** vtable = *reinterpret_cast<void***>(self);
        if (!vtable) return nullptr;
        return reinterpret_cast<PhysicsTraceFn>(vtable[0x150 / sizeof(void*)]);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return nullptr;
    }
}

uintptr_t Hook_PhysicsTraceCall(void* self, void* arg2, void* arg3, void* rayList) {
    const uint32_t fires = s_fires.fetch_add(1, std::memory_order_relaxed) + 1;
    const bool publishedActiveAtEntry = s_publishActive.load(std::memory_order_acquire);

    HeadTrackingState state{};
    if (g_sharedState.IsAvailable()) {
        state = g_sharedState.Read();
    }

    SavedVec3 saved[kMaxSavedVecs]{};
    int savedCount = 0;
    const bool hasPose =
        state.enabled &&
        state.applied_frame > 0 &&
        (std::fabs(state.yaw) >= 0.1f || std::fabs(state.pitch) >= 0.1f);

    if (kEnablePhysicsMutation && hasPose) {
        CompensateTraceBasis(arg3, rayList, state, saved, savedCount);
        if (savedCount > 0) {
            s_compensated.fetch_add(1, std::memory_order_relaxed);
        } else {
            s_lookupFailed.fetch_add(1, std::memory_order_relaxed);
        }
    }

    LogTraceSample("pre", arg2, arg3, rayList, fires, state, savedCount, 0, publishedActiveAtEntry);

    PhysicsTraceFn original = ResolveOriginalPhysicsTrace(self);
    if (!original) {
        LogError("[HeadTrackingAim] physics-call hook failed to resolve original vtable slot");
        RestoreSaved(saved, savedCount);
        return 0;
    }

    const uintptr_t result = original(self, arg2, arg3, rayList);
    if (savedCount > 0 && kRestorePhysicsMutationAfterTrace) {
        RestoreSaved(saved, savedCount);
    }

    LogTraceSample("post", arg2, arg3, rayList, fires, state, savedCount, result, publishedActiveAtEntry);

    if (kPublishPhysicsHookActive &&
        fires >= kSnapCleanProbeCallCount &&
        !s_publishActive.exchange(true, std::memory_order_acq_rel)) {
        LogInfo("[HeadTrackingAim] physics-call probe publishing hitscan active after trace call #%u", fires);
    }

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = HitscanHook_IsActive();
        w->hitscan_hook_fires = fires;
    }

    const uint64_t nowMs = GetTickCount64();
    if (s_lastHeartbeatMs == 0 || nowMs - s_lastHeartbeatMs > 3000) {
        LogInfo("[HeadTrackingAim] physics-call hook heartbeat: fires=%u published_active=%d compensated=%u lookup_failed=%u entries_seen=%u last_saved=%d yaw=%.2f pitch=%.2f",
                fires,
                HitscanHook_IsActive() ? 1 : 0,
                s_compensated.load(std::memory_order_relaxed),
                s_lookupFailed.load(std::memory_order_relaxed),
                s_entriesSeen.load(std::memory_order_relaxed),
                savedCount,
                state.yaw,
                state.pitch);
        s_lastHeartbeatMs = nowMs;
    }

    return result;
}

void* AllocateRelayNear(uint8_t* target) {
    SYSTEM_INFO si{};
    GetSystemInfo(&si);

    const uintptr_t granularity = si.dwAllocationGranularity ? si.dwAllocationGranularity : 0x10000;
    const uintptr_t targetAddr = reinterpret_cast<uintptr_t>(target);
    constexpr uintptr_t kMaxDistance = 0x70000000ull;

    for (uintptr_t distance = granularity; distance < kMaxDistance; distance += granularity) {
        uintptr_t candidates[2] = {
            targetAddr + distance,
            targetAddr > distance ? targetAddr - distance : 0
        };

        for (uintptr_t candidate : candidates) {
            if (candidate == 0) continue;
            candidate &= ~(granularity - 1);
            void* mem = VirtualAlloc(reinterpret_cast<void*>(candidate),
                                     granularity,
                                     MEM_RESERVE | MEM_COMMIT,
                                     PAGE_EXECUTE_READWRITE);
            if (mem) return mem;
        }
    }

    return nullptr;
}

void WriteRelay(void* relay, void* destination) {
    uint8_t code[kRelaySize] = {
        0x48, 0xB8,
        0, 0, 0, 0, 0, 0, 0, 0,
        0xFF, 0xE0
    };

    const uint64_t addr = reinterpret_cast<uint64_t>(destination);
    std::memcpy(code + 2, &addr, sizeof(addr));
    std::memcpy(relay, code, sizeof(code));
    FlushInstructionCache(GetCurrentProcess(), relay, sizeof(code));
}

bool WriteCallPatch(uint8_t* callsite, void* destination) {
    const intptr_t delta = reinterpret_cast<uint8_t*>(destination) - (callsite + kCallPatchSize);
    if (delta < std::numeric_limits<int32_t>::min() ||
        delta > std::numeric_limits<int32_t>::max()) {
        LogError("[HeadTrackingAim] physics-call relay out of rel32 range: delta=%lld",
                 static_cast<long long>(delta));
        return false;
    }

    uint8_t patch[kOriginalCallSize] = {
        0xE8,
        static_cast<uint8_t>(delta & 0xFF),
        static_cast<uint8_t>((delta >> 8) & 0xFF),
        static_cast<uint8_t>((delta >> 16) & 0xFF),
        static_cast<uint8_t>((delta >> 24) & 0xFF),
        0x90,
        0x90
    };

    DWORD oldProtect = 0;
    if (!VirtualProtect(callsite, kOriginalCallSize, PAGE_EXECUTE_READWRITE, &oldProtect)) {
        LogError("[HeadTrackingAim] physics-call VirtualProtect failed: gle=%lu", GetLastError());
        return false;
    }

    std::memcpy(callsite, patch, sizeof(patch));
    FlushInstructionCache(GetCurrentProcess(), callsite, sizeof(patch));

    DWORD ignored = 0;
    VirtualProtect(callsite, kOriginalCallSize, oldProtect, &ignored);
    return true;
}

bool WriteNormalizeCallPatch(uint8_t* callsite, void* destination) {
    const intptr_t delta = reinterpret_cast<uint8_t*>(destination) - (callsite + kNormalizeCallSize);
    if (delta < std::numeric_limits<int32_t>::min() ||
        delta > std::numeric_limits<int32_t>::max()) {
        LogError("[HeadTrackingAim] normalize-call relay out of rel32 range: delta=%lld",
                 static_cast<long long>(delta));
        return false;
    }

    uint8_t patch[kNormalizeCallSize] = {
        0xE8,
        static_cast<uint8_t>(delta & 0xFF),
        static_cast<uint8_t>((delta >> 8) & 0xFF),
        static_cast<uint8_t>((delta >> 16) & 0xFF),
        static_cast<uint8_t>((delta >> 24) & 0xFF)
    };

    DWORD oldProtect = 0;
    if (!VirtualProtect(callsite, kNormalizeCallSize, PAGE_EXECUTE_READWRITE, &oldProtect)) {
        LogError("[HeadTrackingAim] normalize-call VirtualProtect failed: gle=%lu", GetLastError());
        return false;
    }

    std::memcpy(callsite, patch, sizeof(patch));
    FlushInstructionCache(GetCurrentProcess(), callsite, sizeof(patch));

    DWORD ignored = 0;
    VirtualProtect(callsite, kNormalizeCallSize, oldProtect, &ignored);
    return true;
}

bool RestoreCallPatch() {
    if (!s_callsite) return true;

    DWORD oldProtect = 0;
    if (!VirtualProtect(s_callsite, kOriginalCallSize, PAGE_EXECUTE_READWRITE, &oldProtect)) {
        LogError("[HeadTrackingAim] physics-call restore VirtualProtect failed: gle=%lu", GetLastError());
        return false;
    }

    std::memcpy(s_callsite, s_originalBytes, sizeof(s_originalBytes));
    FlushInstructionCache(GetCurrentProcess(), s_callsite, sizeof(s_originalBytes));

    DWORD ignored = 0;
    VirtualProtect(s_callsite, kOriginalCallSize, oldProtect, &ignored);
    return true;
}

bool RestoreNormalizeCallPatch() {
    if (!s_normalizeCallsite) return true;

    DWORD oldProtect = 0;
    if (!VirtualProtect(s_normalizeCallsite, kNormalizeCallSize, PAGE_EXECUTE_READWRITE, &oldProtect)) {
        LogError("[HeadTrackingAim] normalize-call restore VirtualProtect failed: gle=%lu", GetLastError());
        return false;
    }

    std::memcpy(s_normalizeCallsite, s_originalNormalizeCallBytes, sizeof(s_originalNormalizeCallBytes));
    FlushInstructionCache(GetCurrentProcess(), s_normalizeCallsite, sizeof(s_originalNormalizeCallBytes));

    DWORD ignored = 0;
    VirtualProtect(s_normalizeCallsite, kNormalizeCallSize, oldProtect, &ignored);
    return true;
}

bool ResolveNormalizeCallsite() {
    HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
    if (!hModule) return false;

    s_exeBase = reinterpret_cast<uintptr_t>(hModule);
    s_normalizeCallsite = reinterpret_cast<uint8_t*>(s_exeBase + kNormalizeCallsiteOffset);
    s_originalNormalize = reinterpret_cast<NormalizeFn>(s_exeBase + kNormalizeOffset);

    if (s_normalizeCallsite[0] != 0xE8) {
        LogError("[HeadTrackingAim] normalize-call opcode mismatch at +0x%llX",
                 static_cast<unsigned long long>(kNormalizeCallsiteOffset));
        return false;
    }

    const int32_t rel = *reinterpret_cast<int32_t*>(s_normalizeCallsite + 1);
    const uintptr_t target = reinterpret_cast<uintptr_t>(s_normalizeCallsite + kNormalizeCallSize + rel);
    if (target != s_exeBase + kNormalizeOffset) {
        LogError("[HeadTrackingAim] normalize-call target mismatch at +0x%llX target=+0x%llX expected=+0x%llX",
                 static_cast<unsigned long long>(kNormalizeCallsiteOffset),
                 static_cast<unsigned long long>(target - s_exeBase),
                 static_cast<unsigned long long>(kNormalizeOffset));
        return false;
    }

    std::memcpy(s_originalNormalizeCallBytes, s_normalizeCallsite, sizeof(s_originalNormalizeCallBytes));
    return true;
}

bool ResolveTarget() {
    HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
    if (!hModule) return false;

    MODULEINFO info{};
    if (!GetModuleInformation(GetCurrentProcess(), hModule, &info, sizeof(info))) {
        return false;
    }

    s_exeBase = reinterpret_cast<uintptr_t>(info.lpBaseOfDll);
    s_callsite = reinterpret_cast<uint8_t*>(s_exeBase + kPhysicsCallsiteOffset);

    if (std::memcmp(s_callsite, kExpectedCallBytes, sizeof(kExpectedCallBytes)) != 0) {
        LogError("[HeadTrackingAim] physics-call opcode mismatch at +0x%llX",
                 static_cast<unsigned long long>(kPhysicsCallsiteOffset));
        return false;
    }

    std::memcpy(s_originalBytes, s_callsite, sizeof(s_originalBytes));
    return true;
}

} // namespace

bool HitscanHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (s_hooked.load(std::memory_order_acquire)) return true;
    s_publishActive.store(false, std::memory_order_release);
    s_fires.store(0, std::memory_order_relaxed);
    s_candidateAFires.store(0, std::memory_order_relaxed);
    s_candidateBFires.store(0, std::memory_order_relaxed);
    s_targetHelperFires.store(0, std::memory_order_relaxed);
    s_targetHelperMutated.store(0, std::memory_order_relaxed);
    s_targetHelperSkipped.store(0, std::memory_order_relaxed);
    s_targetHelperFaults.store(0, std::memory_order_relaxed);
    s_normalizeFires.store(0, std::memory_order_relaxed);
    s_normalizeMutated.store(0, std::memory_order_relaxed);
    s_normalizeSkipped.store(0, std::memory_order_relaxed);
    s_normalizeFaults.store(0, std::memory_order_relaxed);
    s_traceDispatchCalls.store(0, std::memory_order_relaxed);
    s_traceDispatchWindowCalls.store(0, std::memory_order_relaxed);
    s_traceDispatchMutated.store(0, std::memory_order_relaxed);
    s_traceDispatchSkipped.store(0, std::memory_order_relaxed);
    s_traceDispatchFaults.store(0, std::memory_order_relaxed);
    s_compensated.store(0, std::memory_order_relaxed);
    s_lookupFailed.store(0, std::memory_order_relaxed);
    s_entriesSeen.store(0, std::memory_order_relaxed);
    s_shotQueueConsumerCalls.store(0, std::memory_order_relaxed);
    s_shotQueueConsumerMutated.store(0, std::memory_order_relaxed);
    s_shotQueueConsumerSkipped.store(0, std::memory_order_relaxed);
    s_shotQueueConsumerFaults.store(0, std::memory_order_relaxed);
    s_shotCandidateWriterCalls.store(0, std::memory_order_relaxed);
    s_shotCandidateWriterMutated.store(0, std::memory_order_relaxed);
    s_shotCandidateWriterSkipped.store(0, std::memory_order_relaxed);
    s_shotCandidateWriterFaults.store(0, std::memory_order_relaxed);
    s_shotInputClassifyCalls.store(0, std::memory_order_relaxed);
    s_shotInputClassifyMutated.store(0, std::memory_order_relaxed);
    s_shotInputClassifySkipped.store(0, std::memory_order_relaxed);
    s_shotInputClassifyFaults.store(0, std::memory_order_relaxed);
    s_shotVectorProcessorCalls.store(0, std::memory_order_relaxed);
    s_shotVectorAltProcessorCalls.store(0, std::memory_order_relaxed);
    s_shotFinalVectorWriteCalls.store(0, std::memory_order_relaxed);
    s_shotFinalVectorWriteMutated.store(0, std::memory_order_relaxed);
    s_shotFinalVectorWriteSkipped.store(0, std::memory_order_relaxed);
    s_shotFinalVectorWriteFaults.store(0, std::memory_order_relaxed);
    s_shotVectorMutated.store(0, std::memory_order_relaxed);
    s_shotVectorSkipped.store(0, std::memory_order_relaxed);
    s_shotVectorFaults.store(0, std::memory_order_relaxed);
    s_shotVectorNoPose.store(0, std::memory_order_relaxed);
    s_shotVectorWindowShotSeq.store(0, std::memory_order_relaxed);
    s_shotVectorWindowRestoreSeq.store(0, std::memory_order_relaxed);
    s_shotVectorWindowClickSeq.store(0, std::memory_order_relaxed);
    s_shotVectorWindowMs.store(0, std::memory_order_relaxed);
    s_shotVectorWindowLogBudget.store(0, std::memory_order_relaxed);
    s_shotVectorWindowMutateBudget.store(0, std::memory_order_relaxed);
    s_shotVectorWindowPrimed.store(false, std::memory_order_relaxed);
    s_lastShotVectorSource.store(0, std::memory_order_relaxed);
    s_lastShotVectorNewX.store(0, std::memory_order_relaxed);
    s_lastShotVectorNewY.store(0, std::memory_order_relaxed);
    s_lastShotVectorNewZ.store(0, std::memory_order_relaxed);
    s_lastShotVectorClickSeq.store(0, std::memory_order_relaxed);
    s_shotSourceSkipPredicate = nullptr;
    s_lastHeartbeatMs = 0;

    if (kDisableNativeHitscanHook) {
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
            w->hitscan_hook_fires = 0;
        }
        LogInfo("[HeadTrackingAim] native hitscan hook disabled; SNAP-CLEAN fallback remains enabled");
        return false;
    }

    if (kUseNormalizeCallsitePatch) {
        if (!ResolveNormalizeCallsite()) {
            LogWarning("[HeadTrackingAim] normalize-call hook inactive: target resolution failed");
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            s_normalizeCallsite = nullptr;
            s_originalNormalize = nullptr;
            return false;
        }

        s_normalizeRelay = reinterpret_cast<uint8_t*>(AllocateRelayNear(s_normalizeCallsite));
        if (!s_normalizeRelay) {
            LogError("[HeadTrackingAim] normalize-call hook inactive: failed to allocate nearby relay");
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            s_normalizeCallsite = nullptr;
            s_originalNormalize = nullptr;
            return false;
        }

        WriteRelay(s_normalizeRelay, reinterpret_cast<void*>(&Hook_Normalize));

        if (!WriteNormalizeCallPatch(s_normalizeCallsite, s_normalizeRelay)) {
            VirtualFree(s_normalizeRelay, 0, MEM_RELEASE);
            s_normalizeRelay = nullptr;
            s_normalizeCallsite = nullptr;
            s_originalNormalize = nullptr;
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            return false;
        }

        s_hooked.store(true, std::memory_order_release);
        s_publishActive.store(kPublishNormalizeActive, std::memory_order_release);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires = 0;
        }

        LogInfo("[HeadTrackingAim] normalize-call hitscan compensation active: patched +0x%llX -> relay %p target=+0x%llX publish_active=%d",
                static_cast<unsigned long long>(kNormalizeCallsiteOffset),
                s_normalizeRelay,
                static_cast<unsigned long long>(kNormalizeOffset),
                kPublishNormalizeActive ? 1 : 0);
        return true;
    }

    if (kUseNormalizeHook) {
        if (!sdk) {
            LogError("[HeadTrackingAim] normalize hook inactive: RED4ext SDK unavailable");
            return false;
        }

        HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
        if (!hModule) {
            LogError("[HeadTrackingAim] normalize hook inactive: Cyberpunk2077.exe base unavailable");
            return false;
        }

        s_exeBase = reinterpret_cast<uintptr_t>(hModule);
        s_normalizeTarget = reinterpret_cast<void*>(s_exeBase + kNormalizeOffset);

        const bool attached = sdk->hooking->Attach(handle,
                                                   s_normalizeTarget,
                                                   reinterpret_cast<void*>(&Hook_Normalize),
                                                   reinterpret_cast<void**>(&s_originalNormalize));
        if (!attached) {
            LogError("[HeadTrackingAim] normalize hook inactive: attach failed at +0x%llX",
                     static_cast<unsigned long long>(kNormalizeOffset));
            s_normalizeTarget = nullptr;
            s_originalNormalize = nullptr;
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            return false;
        }

        s_hooked.store(true, std::memory_order_release);
        s_publishActive.store(kPublishNormalizeActive, std::memory_order_release);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires = 0;
        }

        LogInfo("[HeadTrackingAim] normalize hitscan compensation active: hooked +0x%llX target=%p shot_ret=+0x%llX publish_active=%d",
                static_cast<unsigned long long>(kNormalizeOffset),
                s_normalizeTarget,
                static_cast<unsigned long long>(kNormalizeShotReturnOffset),
                kPublishNormalizeActive ? 1 : 0);
        return true;
    }

    if (kUseTargetHelperHook) {
        if (!sdk) {
            LogError("[HeadTrackingAim] target-helper hook inactive: RED4ext SDK unavailable");
            return false;
        }

        HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
        if (!hModule) {
            LogError("[HeadTrackingAim] target-helper hook inactive: Cyberpunk2077.exe base unavailable");
            return false;
        }

        s_exeBase = reinterpret_cast<uintptr_t>(hModule);
        s_targetHelperTarget = reinterpret_cast<void*>(s_exeBase + kTargetHelperOffset);

        const bool attached = sdk->hooking->Attach(handle,
                                                   s_targetHelperTarget,
                                                   reinterpret_cast<void*>(&Hook_TargetHelper),
                                                   reinterpret_cast<void**>(&s_originalTargetHelper));
        if (!attached) {
            LogError("[HeadTrackingAim] target-helper hook inactive: attach failed at +0x%llX",
                     static_cast<unsigned long long>(kTargetHelperOffset));
            s_targetHelperTarget = nullptr;
            s_originalTargetHelper = nullptr;
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            return false;
        }

        s_hooked.store(true, std::memory_order_release);
        s_publishActive.store(kPublishTargetHelperActive, std::memory_order_release);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires = 0;
        }

        LogInfo("[HeadTrackingAim] target-helper hitscan compensation active: hooked +0x%llX target=%p shot_ret=+0x%llX publish_active=%d",
                static_cast<unsigned long long>(kTargetHelperOffset),
                s_targetHelperTarget,
                static_cast<unsigned long long>(kTargetHelperShotReturnOffset),
                kPublishTargetHelperActive ? 1 : 0);
        return true;
    }

    if (kUseTraceDispatchHook) {
        if (!sdk) {
            LogError("[HeadTrackingAim] trace-dispatch hook inactive: RED4ext SDK unavailable");
            return false;
        }

        HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
        if (!hModule) {
            LogError("[HeadTrackingAim] trace-dispatch hook inactive: Cyberpunk2077.exe base unavailable");
            return false;
        }

        s_exeBase = reinterpret_cast<uintptr_t>(hModule);
        s_traceDispatchTarget = reinterpret_cast<void*>(s_exeBase + kTraceDispatchOffset);

        const bool attached = sdk->hooking->Attach(handle,
                                                   s_traceDispatchTarget,
                                                   reinterpret_cast<void*>(&Hook_TraceDispatch),
                                                   reinterpret_cast<void**>(&s_originalTraceDispatch));
        if (!attached) {
            LogError("[HeadTrackingAim] trace-dispatch hook inactive: attach failed at +0x%llX",
                     static_cast<unsigned long long>(kTraceDispatchOffset));
            s_traceDispatchTarget = nullptr;
            s_originalTraceDispatch = nullptr;
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            return false;
        }

        s_hooked.store(true, std::memory_order_release);
        s_publishActive.store(kPublishTraceDispatchActive, std::memory_order_release);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires = 0;
        }

        LogInfo("[HeadTrackingAim] trace-dispatch hitscan compensation active: hooked +0x%llX target=%p publish_active=%d require_window=%d mutate=%d",
                static_cast<unsigned long long>(kTraceDispatchOffset),
                s_traceDispatchTarget,
                kPublishTraceDispatchActive ? 1 : 0,
                kTraceDispatchRequireShotWindow ? 1 : 0,
                kMutateTraceDispatchRay ? 1 : 0);
        return true;
    }

    if (kUseRayDispatchProbe) {
        if (!sdk) {
            LogError("[HeadTrackingAim] ray-dispatch probe inactive: RED4ext SDK unavailable");
            return false;
        }

        HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
        if (!hModule) {
            LogError("[HeadTrackingAim] ray-dispatch probe inactive: Cyberpunk2077.exe base unavailable");
            return false;
        }

        s_exeBase = reinterpret_cast<uintptr_t>(hModule);
        s_rayDispatchTarget = reinterpret_cast<void*>(s_exeBase + kRayDispatchOffset);

        const bool attached = sdk->hooking->Attach(handle,
                                                   s_rayDispatchTarget,
                                                   reinterpret_cast<void*>(&Hook_RayDispatch),
                                                   reinterpret_cast<void**>(&s_originalRayDispatch));
        if (!attached) {
            LogError("[HeadTrackingAim] ray-dispatch probe inactive: hook attach failed at +0x%llX",
                     static_cast<unsigned long long>(kRayDispatchOffset));
            s_rayDispatchTarget = nullptr;
            s_originalRayDispatch = nullptr;
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            return false;
        }

        s_hooked.store(true, std::memory_order_release);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
            w->hitscan_hook_fires = 0;
        }

        LogInfo("[HeadTrackingAim] ray-dispatch probe active: hooked +0x%llX target=%p; SNAP-CLEAN remains enabled",
                static_cast<unsigned long long>(kRayDispatchOffset),
                s_rayDispatchTarget);
        return true;
    }

    if (kUseShotQueueConsumerProbe) {
        if (!sdk) {
            LogError("[HeadTrackingAim] shot-queue hook inactive: RED4ext SDK unavailable");
            return false;
        }

        HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
        if (!hModule) {
            LogError("[HeadTrackingAim] shot-queue hook inactive: Cyberpunk2077.exe base unavailable");
            return false;
        }

        s_exeBase = reinterpret_cast<uintptr_t>(hModule);
        s_shotQueueConsumerTarget = reinterpret_cast<void*>(s_exeBase + kShotQueueConsumerOffset);

        const bool attached = sdk->hooking->Attach(handle,
                                                   s_shotQueueConsumerTarget,
                                                   reinterpret_cast<void*>(&Hook_ShotQueueConsumer),
                                                   reinterpret_cast<void**>(&s_originalShotQueueConsumer));
        if (!attached) {
            LogError("[HeadTrackingAim] shot-queue hook inactive: attach failed at +0x%llX",
                     static_cast<unsigned long long>(kShotQueueConsumerOffset));
            s_shotQueueConsumerTarget = nullptr;
            s_originalShotQueueConsumer = nullptr;
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            return false;
        }

        s_hooked.store(true, std::memory_order_release);
        s_publishActive.store(kPublishShotQueueConsumerActive, std::memory_order_release);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires = 0;
        }

        LogInfo("[HeadTrackingAim] shot-queue hitscan compensation active: hooked +0x%llX publish_active=%d mutate=%d",
                static_cast<unsigned long long>(kShotQueueConsumerOffset),
                kPublishShotQueueConsumerActive ? 1 : 0,
                kMutateShotQueueConsumerSources ? 1 : 0);
        return true;
    }

    if (kUseShotQueueBuildProbe) {
        if (!sdk) {
            LogError("[HeadTrackingAim] shot-build hook inactive: RED4ext SDK unavailable");
            return false;
        }

        HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
        if (!hModule) {
            LogError("[HeadTrackingAim] shot-build hook inactive: Cyberpunk2077.exe base unavailable");
            return false;
        }

        s_exeBase = reinterpret_cast<uintptr_t>(hModule);
        s_shotQueueBuildTarget = reinterpret_cast<void*>(s_exeBase + kShotQueueBuildOffset);

        const bool attached = sdk->hooking->Attach(handle,
                                                   s_shotQueueBuildTarget,
                                                   reinterpret_cast<void*>(&Hook_ShotQueueBuild),
                                                   reinterpret_cast<void**>(&s_originalShotQueueBuild));
        if (!attached) {
            LogError("[HeadTrackingAim] shot-build hook inactive: attach failed at +0x%llX",
                     static_cast<unsigned long long>(kShotQueueBuildOffset));
            s_shotQueueBuildTarget = nullptr;
            s_originalShotQueueBuild = nullptr;
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            return false;
        }

        s_hooked.store(true, std::memory_order_release);
        s_publishActive.store(kPublishShotQueueBuildActive, std::memory_order_release);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires = 0;
        }

        LogInfo("[HeadTrackingAim] shot-build probe active: hooked +0x%llX publish_active=%d",
                static_cast<unsigned long long>(kShotQueueBuildOffset),
                kPublishShotQueueBuildActive ? 1 : 0);
        return true;
    }

    if (kUseShotCandidateWriterHook) {
        if (!sdk) {
            LogError("[HeadTrackingAim] shot-writer hook inactive: RED4ext SDK unavailable");
            return false;
        }

        HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
        if (!hModule) {
            LogError("[HeadTrackingAim] shot-writer hook inactive: Cyberpunk2077.exe base unavailable");
            return false;
        }

        s_exeBase = reinterpret_cast<uintptr_t>(hModule);
        s_shotCandidateWriterTarget = reinterpret_cast<void*>(s_exeBase + kShotCandidateWriterOffset);

        const bool attached = sdk->hooking->Attach(handle,
                                                   s_shotCandidateWriterTarget,
                                                   reinterpret_cast<void*>(&Hook_ShotCandidateWriter),
                                                   reinterpret_cast<void**>(&s_originalShotCandidateWriter));
        if (!attached) {
            LogError("[HeadTrackingAim] shot-writer hook inactive: attach failed at +0x%llX",
                     static_cast<unsigned long long>(kShotCandidateWriterOffset));
            s_shotCandidateWriterTarget = nullptr;
            s_originalShotCandidateWriter = nullptr;
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            return false;
        }

        s_hooked.store(true, std::memory_order_release);
        s_publishActive.store(kPublishShotCandidateWriterActive, std::memory_order_release);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires = 0;
        }

        LogInfo("[HeadTrackingAim] shot-writer hitscan compensation active: hooked +0x%llX publish_active=%d mutate=%d",
                static_cast<unsigned long long>(kShotCandidateWriterOffset),
                kPublishShotCandidateWriterActive ? 1 : 0,
                kMutateShotCandidateWriterOutput ? 1 : 0);
        return true;
    }

    if (kUseShotCandidateLinkHook) {
        if (!sdk) {
            LogError("[HeadTrackingAim] shot-link hook inactive: RED4ext SDK unavailable");
            return false;
        }

        HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
        if (!hModule) {
            LogError("[HeadTrackingAim] shot-link hook inactive: Cyberpunk2077.exe base unavailable");
            return false;
        }

        s_exeBase = reinterpret_cast<uintptr_t>(hModule);
        s_shotCandidateLinkTarget = reinterpret_cast<void*>(s_exeBase + kShotCandidateLinkOffset);

        const bool attached = sdk->hooking->Attach(handle,
                                                   s_shotCandidateLinkTarget,
                                                   reinterpret_cast<void*>(&Hook_ShotCandidateLink),
                                                   reinterpret_cast<void**>(&s_originalShotCandidateLink));
        if (!attached) {
            LogError("[HeadTrackingAim] shot-link hook inactive: attach failed at +0x%llX",
                     static_cast<unsigned long long>(kShotCandidateLinkOffset));
            s_shotCandidateLinkTarget = nullptr;
            s_originalShotCandidateLink = nullptr;
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            return false;
        }

        s_hooked.store(true, std::memory_order_release);
        s_publishActive.store(kPublishShotCandidateLinkActive, std::memory_order_release);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires = 0;
        }

        LogInfo("[HeadTrackingAim] shot-link probe active: hooked +0x%llX publish_active=%d",
                static_cast<unsigned long long>(kShotCandidateLinkOffset),
                kPublishShotCandidateLinkActive ? 1 : 0);
        return true;
    }

    if (kUseShotCandidateGateProbe) {
        if (!sdk) {
            LogError("[HeadTrackingAim] shot-gate hook inactive: RED4ext SDK unavailable");
            return false;
        }

        HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
        if (!hModule) {
            LogError("[HeadTrackingAim] shot-gate hook inactive: Cyberpunk2077.exe base unavailable");
            return false;
        }

        s_exeBase = reinterpret_cast<uintptr_t>(hModule);
        s_shotCandidateGateTarget = reinterpret_cast<void*>(s_exeBase + kShotCandidateGateOffset);

        const bool attached = sdk->hooking->Attach(handle,
                                                   s_shotCandidateGateTarget,
                                                   reinterpret_cast<void*>(&Hook_ShotCandidateGate),
                                                   reinterpret_cast<void**>(&s_originalShotCandidateGate));
        if (!attached) {
            LogError("[HeadTrackingAim] shot-gate hook inactive: attach failed at +0x%llX",
                     static_cast<unsigned long long>(kShotCandidateGateOffset));
            s_shotCandidateGateTarget = nullptr;
            s_originalShotCandidateGate = nullptr;
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            return false;
        }

        s_hooked.store(true, std::memory_order_release);
        s_publishActive.store(kPublishShotCandidateGateActive, std::memory_order_release);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires = 0;
        }

        LogInfo("[HeadTrackingAim] shot-gate probe active: hooked +0x%llX publish_active=%d",
                static_cast<unsigned long long>(kShotCandidateGateOffset),
                kPublishShotCandidateGateActive ? 1 : 0);
        return true;
    }

    if (kUseShotFinalVectorWriteHook) {
        if (!sdk) {
            LogError("[HeadTrackingAim] shot-final hook inactive: RED4ext SDK unavailable");
            return false;
        }

        HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
        if (!hModule) {
            LogError("[HeadTrackingAim] shot-final hook inactive: Cyberpunk2077.exe base unavailable");
            return false;
        }

        s_exeBase = reinterpret_cast<uintptr_t>(hModule);
        s_shotFinalVectorWriteTarget = reinterpret_cast<void*>(s_exeBase + kShotFinalVectorWriteOffset);

        const bool attached = sdk->hooking->Attach(handle,
                                                   s_shotFinalVectorWriteTarget,
                                                   reinterpret_cast<void*>(&Hook_ShotFinalVectorWrite),
                                                   reinterpret_cast<void**>(&s_originalShotFinalVectorWrite));
        if (!attached) {
            LogError("[HeadTrackingAim] shot-final hook inactive: attach failed at +0x%llX",
                     static_cast<unsigned long long>(kShotFinalVectorWriteOffset));
            s_shotFinalVectorWriteTarget = nullptr;
            s_originalShotFinalVectorWrite = nullptr;
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            return false;
        }

        s_hooked.store(true, std::memory_order_release);
        s_publishActive.store(kPublishShotFinalVectorWriteActive, std::memory_order_release);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires = 0;
        }

        LogInfo("[HeadTrackingAim] shot-final hitscan compensation active: hooked +0x%llX publish_active=%d mutate=%d budget=%u",
                static_cast<unsigned long long>(kShotFinalVectorWriteOffset),
                kPublishShotFinalVectorWriteActive ? 1 : 0,
                kMutateShotFinalVectorWrite ? 1 : 0,
                kShotVectorWindowMutateBudget);
        return true;
    }

    if (kUseShotInputClassifyHook) {
        if (!sdk) {
            LogError("[HeadTrackingAim] shot-classify hook inactive: RED4ext SDK unavailable");
            return false;
        }

        HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
        if (!hModule) {
            LogError("[HeadTrackingAim] shot-classify hook inactive: Cyberpunk2077.exe base unavailable");
            return false;
        }

        s_exeBase = reinterpret_cast<uintptr_t>(hModule);
        s_shotInputClassifyTarget = reinterpret_cast<void*>(s_exeBase + kShotInputClassifyOffset);

        const bool attached = sdk->hooking->Attach(handle,
                                                   s_shotInputClassifyTarget,
                                                   reinterpret_cast<void*>(&Hook_ShotInputClassify),
                                                   reinterpret_cast<void**>(&s_originalShotInputClassify));
        if (!attached) {
            LogError("[HeadTrackingAim] shot-classify hook inactive: attach failed at +0x%llX",
                     static_cast<unsigned long long>(kShotInputClassifyOffset));
            s_shotInputClassifyTarget = nullptr;
            s_originalShotInputClassify = nullptr;
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            return false;
        }

        s_hooked.store(true, std::memory_order_release);
        s_publishActive.store(kPublishShotInputClassifyActive, std::memory_order_release);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires = 0;
        }

        LogInfo("[HeadTrackingAim] shot-classify hitscan compensation active: hooked +0x%llX publish_active=%d mutate=%d returns=(+0x%llX,+0x%llX)",
                static_cast<unsigned long long>(kShotInputClassifyOffset),
                kPublishShotInputClassifyActive ? 1 : 0,
                kMutateShotInputClassifyTarget ? 1 : 0,
                static_cast<unsigned long long>(kShotInputClassifyReturnProcessorOffset),
                static_cast<unsigned long long>(kShotInputClassifyReturnAltProcessorOffset));
        return true;
    }

    if (kUseShotVectorSourceHook) {
        if (!sdk) {
            LogError("[HeadTrackingAim] shot-vector hook inactive: RED4ext SDK unavailable");
            return false;
        }

        HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
        if (!hModule) {
            LogError("[HeadTrackingAim] shot-vector hook inactive: Cyberpunk2077.exe base unavailable");
            return false;
        }

        s_exeBase = reinterpret_cast<uintptr_t>(hModule);
        s_shotSourceSkipPredicate =
            reinterpret_cast<ShotSourceSkipPredicateFn>(s_exeBase + kShotSourceSkipPredicateOffset);
        s_shotVectorProcessorTarget = reinterpret_cast<void*>(s_exeBase + kShotVectorProcessorOffset);
        s_shotVectorAltProcessorTarget = reinterpret_cast<void*>(s_exeBase + kShotVectorAltProcessorOffset);

        const bool attachedProcessor = sdk->hooking->Attach(handle,
                                                            s_shotVectorProcessorTarget,
                                                            reinterpret_cast<void*>(&Hook_ShotVectorProcessor),
                                                            reinterpret_cast<void**>(&s_originalShotVectorProcessor));
        if (!attachedProcessor) {
            LogError("[HeadTrackingAim] shot-vector hook inactive: attach failed at +0x%llX",
                     static_cast<unsigned long long>(kShotVectorProcessorOffset));
            s_shotVectorProcessorTarget = nullptr;
            s_shotVectorAltProcessorTarget = nullptr;
            s_originalShotVectorProcessor = nullptr;
            s_originalShotVectorAltProcessor = nullptr;
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            return false;
        }

        const bool attachedAltProcessor = sdk->hooking->Attach(handle,
                                                               s_shotVectorAltProcessorTarget,
                                                               reinterpret_cast<void*>(&Hook_ShotVectorAltProcessor),
                                                               reinterpret_cast<void**>(&s_originalShotVectorAltProcessor));
        if (!attachedAltProcessor) {
            sdk->hooking->Detach(handle, s_shotVectorProcessorTarget);
            LogError("[HeadTrackingAim] shot-vector hook inactive: attach failed at +0x%llX",
                     static_cast<unsigned long long>(kShotVectorAltProcessorOffset));
            s_shotVectorProcessorTarget = nullptr;
            s_shotVectorAltProcessorTarget = nullptr;
            s_originalShotVectorProcessor = nullptr;
            s_originalShotVectorAltProcessor = nullptr;
            if (HeadTrackingState* w = g_sharedState.GetWritable()) {
                w->hitscan_hook_active = false;
                w->hitscan_hook_fires = 0;
            }
            return false;
        }

        s_hooked.store(true, std::memory_order_release);
        s_publishActive.store(kPublishShotVectorSourceActive, std::memory_order_release);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires = 0;
        }

        LogInfo("[HeadTrackingAim] shot-vector post-shot restore active: hooked +0x%llX and +0x%llX predicate=+0x%llX publish_active=%d mutate=%d alt_mutate=%d post_mutate=%d restore=%d budget=%u",
                static_cast<unsigned long long>(kShotVectorProcessorOffset),
                static_cast<unsigned long long>(kShotVectorAltProcessorOffset),
                static_cast<unsigned long long>(kShotSourceSkipPredicateOffset),
                kPublishShotVectorSourceActive ? 1 : 0,
                kMutateShotVectorSource ? 1 : 0,
                kMutateShotVectorAltSource ? 1 : 0,
                kMutateShotVectorSourceAfterCall ? 1 : 0,
                kRestoreShotVectorSourceAfterCall ? 1 : 0,
                kShotVectorWindowMutateBudget);
        return true;
    }

    if (kUseShotOrchestratorProbe) {
        if (!sdk) {
            LogError("[HeadTrackingAim] shot-probe inactive: RED4ext SDK unavailable");
            return false;
        }

        HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
        if (!hModule) {
            LogError("[HeadTrackingAim] shot-probe inactive: Cyberpunk2077.exe base unavailable");
            return false;
        }

        s_exeBase = reinterpret_cast<uintptr_t>(hModule);
        s_shotCandidateATarget = reinterpret_cast<void*>(s_exeBase + kShotCandidateAOffset);
        s_shotCandidateBTarget = reinterpret_cast<void*>(s_exeBase + kShotCandidateBOffset);

        const bool attachedA = sdk->hooking->Attach(handle,
                                                    s_shotCandidateATarget,
                                                    reinterpret_cast<void*>(&Hook_ShotCandidateA),
                                                    reinterpret_cast<void**>(&s_originalShotCandidateA));
        if (!attachedA) {
            LogError("[HeadTrackingAim] shot-probe inactive: attach failed at +0x%llX",
                     static_cast<unsigned long long>(kShotCandidateAOffset));
            s_shotCandidateATarget = nullptr;
            s_shotCandidateBTarget = nullptr;
            s_originalShotCandidateA = nullptr;
            s_originalShotCandidateB = nullptr;
            return false;
        }

        const bool attachedB = sdk->hooking->Attach(handle,
                                                    s_shotCandidateBTarget,
                                                    reinterpret_cast<void*>(&Hook_ShotCandidateB),
                                                    reinterpret_cast<void**>(&s_originalShotCandidateB));
        if (!attachedB) {
            sdk->hooking->Detach(handle, s_shotCandidateATarget);
            LogError("[HeadTrackingAim] shot-probe inactive: attach failed at +0x%llX",
                     static_cast<unsigned long long>(kShotCandidateBOffset));
            s_shotCandidateATarget = nullptr;
            s_shotCandidateBTarget = nullptr;
            s_originalShotCandidateA = nullptr;
            s_originalShotCandidateB = nullptr;
            return false;
        }

        s_hooked.store(true, std::memory_order_release);
        s_publishActive.store(kPublishShotOrchestratorActive, std::memory_order_release);
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = HitscanHook_IsActive();
            w->hitscan_hook_fires = 0;
        }

        LogInfo("[HeadTrackingAim] shot-orchestrator hitscan compensation active: hooked +0x%llX and +0x%llX publish_active=%d mutate=%d",
                static_cast<unsigned long long>(kShotCandidateAOffset),
                static_cast<unsigned long long>(kShotCandidateBOffset),
                kPublishShotOrchestratorActive ? 1 : 0,
                kMutateShotOrchestratorSource ? 1 : 0);
        return true;
    }

    if (!ResolveTarget()) {
        LogWarning("[HeadTrackingAim] physics-call hook inactive: target resolution failed");
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
            w->hitscan_hook_fires = 0;
        }
        return false;
    }

    s_relay = reinterpret_cast<uint8_t*>(AllocateRelayNear(s_callsite));
    if (!s_relay) {
        LogError("[HeadTrackingAim] physics-call hook inactive: failed to allocate nearby relay");
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
            w->hitscan_hook_fires = 0;
        }
        return false;
    }

    WriteRelay(s_relay, reinterpret_cast<void*>(&Hook_PhysicsTraceCall));

    if (!WriteCallPatch(s_callsite, s_relay)) {
        VirtualFree(s_relay, 0, MEM_RELEASE);
        s_relay = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
            w->hitscan_hook_fires = 0;
        }
        return false;
    }

    s_hooked.store(true, std::memory_order_release);
    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = true;
        w->hitscan_hook_fires = 0;
    }

    LogInfo("[HeadTrackingAim] physics-call hitscan compensation active: patched +0x%llX -> relay %p mutate=%d restore=%d publish_active=%d",
            static_cast<unsigned long long>(kPhysicsCallsiteOffset),
            s_relay,
            kEnablePhysicsMutation ? 1 : 0,
            kRestorePhysicsMutationAfterTrace ? 1 : 0,
            kPublishPhysicsHookActive ? 1 : 0);
    return true;
}

void HitscanHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (!s_hooked.exchange(false, std::memory_order_acq_rel)) return;
    s_publishActive.store(false, std::memory_order_release);

    if (kUseNormalizeCallsitePatch) {
        RestoreNormalizeCallPatch();
        if (s_normalizeRelay) {
            VirtualFree(s_normalizeRelay, 0, MEM_RELEASE);
            s_normalizeRelay = nullptr;
        }
        s_normalizeCallsite = nullptr;
        s_originalNormalize = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }
        LogInfo("[HeadTrackingAim] normalize-call hook detached");
        return;
    }

    if (kUseNormalizeHook) {
        if (sdk && s_normalizeTarget) {
            sdk->hooking->Detach(handle, s_normalizeTarget);
        }
        s_normalizeTarget = nullptr;
        s_originalNormalize = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }
        LogInfo("[HeadTrackingAim] normalize hook detached");
        return;
    }

    if (kUseTargetHelperHook) {
        if (sdk && s_targetHelperTarget) {
            sdk->hooking->Detach(handle, s_targetHelperTarget);
        }
        s_targetHelperTarget = nullptr;
        s_originalTargetHelper = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }
        LogInfo("[HeadTrackingAim] target-helper hook detached");
        return;
    }

    if (kUseTraceDispatchHook) {
        if (sdk && s_traceDispatchTarget) {
            sdk->hooking->Detach(handle, s_traceDispatchTarget);
        }
        s_traceDispatchTarget = nullptr;
        s_originalTraceDispatch = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }
        LogInfo("[HeadTrackingAim] trace-dispatch hook detached");
        return;
    }

    if (kUseRayDispatchProbe) {
        if (sdk && s_rayDispatchTarget) {
            sdk->hooking->Detach(handle, s_rayDispatchTarget);
        }
        s_rayDispatchTarget = nullptr;
        s_originalRayDispatch = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }
        LogInfo("[HeadTrackingAim] ray-dispatch probe detached");
        return;
    }

    if (kUseShotQueueConsumerProbe) {
        if (sdk && s_shotQueueConsumerTarget) {
            sdk->hooking->Detach(handle, s_shotQueueConsumerTarget);
        }
        s_shotQueueConsumerTarget = nullptr;
        s_originalShotQueueConsumer = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }
        LogInfo("[HeadTrackingAim] shot-queue hook detached");
        return;
    }

    if (kUseShotQueueBuildProbe) {
        if (sdk && s_shotQueueBuildTarget) {
            sdk->hooking->Detach(handle, s_shotQueueBuildTarget);
        }
        s_shotQueueBuildTarget = nullptr;
        s_originalShotQueueBuild = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }
        LogInfo("[HeadTrackingAim] shot-build hook detached");
        return;
    }

    if (kUseShotCandidateWriterHook) {
        if (sdk && s_shotCandidateWriterTarget) {
            sdk->hooking->Detach(handle, s_shotCandidateWriterTarget);
        }
        s_shotCandidateWriterTarget = nullptr;
        s_originalShotCandidateWriter = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }
        LogInfo("[HeadTrackingAim] shot-writer hook detached");
        return;
    }

    if (kUseShotCandidateLinkHook) {
        if (sdk && s_shotCandidateLinkTarget) {
            sdk->hooking->Detach(handle, s_shotCandidateLinkTarget);
        }
        s_shotCandidateLinkTarget = nullptr;
        s_originalShotCandidateLink = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }
        LogInfo("[HeadTrackingAim] shot-link hook detached");
        return;
    }

    if (kUseShotCandidateGateProbe) {
        if (sdk && s_shotCandidateGateTarget) {
            sdk->hooking->Detach(handle, s_shotCandidateGateTarget);
        }
        s_shotCandidateGateTarget = nullptr;
        s_originalShotCandidateGate = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }
        LogInfo("[HeadTrackingAim] shot-gate hook detached");
        return;
    }

    if (kUseShotFinalVectorWriteHook) {
        if (sdk && s_shotFinalVectorWriteTarget) {
            sdk->hooking->Detach(handle, s_shotFinalVectorWriteTarget);
        }
        s_shotFinalVectorWriteTarget = nullptr;
        s_originalShotFinalVectorWrite = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }
        LogInfo("[HeadTrackingAim] shot-final hook detached");
        return;
    }

    if (kUseShotInputClassifyHook) {
        if (sdk && s_shotInputClassifyTarget) {
            sdk->hooking->Detach(handle, s_shotInputClassifyTarget);
        }
        s_shotInputClassifyTarget = nullptr;
        s_originalShotInputClassify = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }
        LogInfo("[HeadTrackingAim] shot-classify hook detached");
        return;
    }

    if (kUseShotVectorSourceHook) {
        if (sdk && s_shotVectorProcessorTarget) {
            sdk->hooking->Detach(handle, s_shotVectorProcessorTarget);
        }
        if (sdk && s_shotVectorAltProcessorTarget) {
            sdk->hooking->Detach(handle, s_shotVectorAltProcessorTarget);
        }
        s_shotVectorProcessorTarget = nullptr;
        s_shotVectorAltProcessorTarget = nullptr;
        s_originalShotVectorProcessor = nullptr;
        s_originalShotVectorAltProcessor = nullptr;
        s_shotSourceSkipPredicate = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }
        LogInfo("[HeadTrackingAim] shot-vector hook detached");
        return;
    }

    if (kUseShotOrchestratorProbe) {
        if (sdk && s_shotCandidateATarget) {
            sdk->hooking->Detach(handle, s_shotCandidateATarget);
        }
        if (sdk && s_shotCandidateBTarget) {
            sdk->hooking->Detach(handle, s_shotCandidateBTarget);
        }
        s_shotCandidateATarget = nullptr;
        s_shotCandidateBTarget = nullptr;
        s_originalShotCandidateA = nullptr;
        s_originalShotCandidateB = nullptr;
        if (HeadTrackingState* w = g_sharedState.GetWritable()) {
            w->hitscan_hook_active = false;
        }
        LogInfo("[HeadTrackingAim] shot-probe detached");
        return;
    }

    RestoreCallPatch();

    if (s_relay) {
        VirtualFree(s_relay, 0, MEM_RELEASE);
        s_relay = nullptr;
    }

    if (HeadTrackingState* w = g_sharedState.GetWritable()) {
        w->hitscan_hook_active = false;
    }

    s_callsite = nullptr;
    LogInfo("[HeadTrackingAim] physics-call hook detached");
}

bool HitscanHook_IsActive() {
    if (kDisableNativeHitscanHook) return false;
    if (kUseNormalizeCallsitePatch) {
        return s_hooked.load(std::memory_order_acquire) &&
               s_publishActive.load(std::memory_order_acquire);
    }
    if (kUseNormalizeHook) {
        return s_hooked.load(std::memory_order_acquire) &&
               s_publishActive.load(std::memory_order_acquire);
    }
    if (kUseTargetHelperHook) {
        return s_hooked.load(std::memory_order_acquire) &&
               s_publishActive.load(std::memory_order_acquire);
    }
    if (kUseTraceDispatchHook) {
        return s_hooked.load(std::memory_order_acquire) &&
               s_publishActive.load(std::memory_order_acquire);
    }
    if (kUseShotQueueConsumerProbe) {
        return s_hooked.load(std::memory_order_acquire) &&
               s_publishActive.load(std::memory_order_acquire);
    }
    if (kUseShotQueueBuildProbe) {
        return s_hooked.load(std::memory_order_acquire) &&
               s_publishActive.load(std::memory_order_acquire);
    }
    if (kUseShotCandidateWriterHook) {
        return s_hooked.load(std::memory_order_acquire) &&
               s_publishActive.load(std::memory_order_acquire);
    }
    if (kUseShotCandidateLinkHook) {
        return s_hooked.load(std::memory_order_acquire) &&
               s_publishActive.load(std::memory_order_acquire);
    }
    if (kUseShotCandidateGateProbe) {
        return s_hooked.load(std::memory_order_acquire) &&
               s_publishActive.load(std::memory_order_acquire);
    }
    if (kUseShotFinalVectorWriteHook) {
        return s_hooked.load(std::memory_order_acquire) &&
               s_publishActive.load(std::memory_order_acquire);
    }
    if (kUseShotInputClassifyHook) {
        return s_hooked.load(std::memory_order_acquire) &&
               s_publishActive.load(std::memory_order_acquire);
    }
    if (kUseShotVectorSourceHook) {
        return s_hooked.load(std::memory_order_acquire) &&
               s_publishActive.load(std::memory_order_acquire);
    }
    if (kUseShotOrchestratorProbe) {
        return s_hooked.load(std::memory_order_acquire) &&
               s_publishActive.load(std::memory_order_acquire);
    }
    if (kUseRayDispatchProbe) return false;
    if (!kPublishPhysicsHookActive) return false;
    return s_hooked.load(std::memory_order_acquire) &&
           s_publishActive.load(std::memory_order_acquire);
}
