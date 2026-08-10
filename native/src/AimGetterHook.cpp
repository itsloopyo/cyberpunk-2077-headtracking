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

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>

#include "NativeRunningHook.hpp"
#include "SharedState.hpp"

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

constexpr uintptr_t kGetWorldOrientationRva = 0x802390;
constexpr uintptr_t kGetWorldTransformRva   = 0x1D92A0;
constexpr uintptr_t kFireNormaliseCallRva   = 0x84C968;
constexpr uintptr_t kNormaliseFnRva         = 0x13DE80;

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

std::atomic<uint32_t> s_callsA{0}, s_callsB{0}, s_callsC{0};
std::atomic<uint32_t> s_matchA{0}, s_matchB{0}, s_matchC{0};
std::atomic<uint32_t> s_overrides{0};
uint32_t              s_loggedA = 0, s_loggedB = 0, s_loggedC = 0;
uint64_t              s_lastHeartbeatMs = 0;
uint32_t              s_lastCallsA = 0, s_lastCallsB = 0, s_lastCallsC = 0;

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

inline void QuatMul(float ax, float ay, float az, float aw,
                    float bx, float by, float bz, float bw,
                    float& ox, float& oy, float& oz, float& ow) {
    ox = aw*bx + ax*bw + ay*bz - az*by;
    oy = aw*by - ax*bz + ay*bw + az*bx;
    oz = aw*bz + ax*by - ay*bx + az*bw;
    ow = aw*bw - ax*bx - ay*by - az*bz;
}

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

void* Hook_GetWorldOrientation(void* rcx, void* rdx) {
    void* ret = s_origA ? s_origA(rcx, rdx) : nullptr;
    const uint32_t mode = s_mode.load(std::memory_order_relaxed);
    if (mode == kModeOff) return ret;

    s_callsA.fetch_add(1, std::memory_order_relaxed);
    const bool peel = (mode == kModePeelA) && InFireWindow();
    const bool testYaw = (mode == kModeTestYawA) && InFireWindow();
    float dot = 0.0f;
    const bool rewrote = HandleCameraQuat(rdx, peel, &dot, testYaw);
    if (dot >= kCamMatchDot) s_matchA.fetch_add(1, std::memory_order_relaxed);

    if (s_loggedA < 8 && dot >= kCamMatchDot) {
        ++s_loggedA;
        LogInfo("[AimGetter] A +0x802390 dot=%.5f peel=%d rewrote=%d", dot, peel ? 1 : 0, rewrote ? 1 : 0);
    }
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
    if (dot >= kCamMatchDot) s_matchB.fetch_add(1, std::memory_order_relaxed);

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

bool PatchFireNormaliseCallsite(uintptr_t exeBase) {
    s_origC = reinterpret_cast<NormaliseFn>(exeBase + kNormaliseFnRva);
    s_callsite = reinterpret_cast<uint8_t*>(exeBase + kFireNormaliseCallRva);

    // Refuse on anything but the exact `call Normalize` this was derived
    // against - a moved call site means a patched game, and a blind write there
    // would corrupt whatever took its place.
    if (s_callsite[0] != 0xE8) {
        LogWarning("[AimGetter] C: +0x%llX is not a direct call (0x%02X) - lever disabled",
                   (unsigned long long)kFireNormaliseCallRva, s_callsite[0]);
        return false;
    }
    int32_t rel = 0;
    std::memcpy(&rel, s_callsite + 1, 4);
    if (reinterpret_cast<uintptr_t>(s_callsite + 5 + rel) != exeBase + kNormaliseFnRva) {
        LogWarning("[AimGetter] C: +0x%llX does not call Normalize - lever disabled",
                   (unsigned long long)kFireNormaliseCallRva);
        return false;
    }

    s_relay = AllocRelayNear(s_callsite);
    if (!s_relay) {
        LogError("[AimGetter] C: no relay page within reach of the call site");
        return false;
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
        return false;
    }
    std::memcpy(s_callsiteOrig, s_callsite, sizeof(s_callsiteOrig));

    uint8_t patch[5] = { 0xE8, 0, 0, 0, 0 };
    const int32_t rel32 = static_cast<int32_t>(delta);
    std::memcpy(patch + 1, &rel32, 4);

    DWORD oldProtect = 0;
    if (!VirtualProtect(s_callsite, sizeof(patch), PAGE_EXECUTE_READWRITE, &oldProtect)) {
        LogError("[AimGetter] C: VirtualProtect failed on the call site");
        return false;
    }
    std::memcpy(s_callsite, patch, sizeof(patch));
    FlushInstructionCache(GetCurrentProcess(), s_callsite, sizeof(patch));
    DWORD ignored = 0;
    VirtualProtect(s_callsite, sizeof(patch), oldProtect, &ignored);
    LogInfo("[AimGetter] C: call site +0x%llX routed through the head peel",
            (unsigned long long)kFireNormaliseCallRva);
    return true;
}

}  // namespace

bool AimGetterHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle) {
    if (s_started.load(std::memory_order_acquire)) return true;
    if (!sdk) return false;

    HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
    if (!hModule) {
        LogError("[AimGetter] Cyberpunk2077.exe handle not found");
        return false;
    }
    const uintptr_t base = reinterpret_cast<uintptr_t>(hModule);

    s_targetA = reinterpret_cast<void*>(base + kGetWorldOrientationRva);
    if (!sdk->hooking->Attach(handle, s_targetA, reinterpret_cast<void*>(&Hook_GetWorldOrientation),
                              reinterpret_cast<void**>(&s_origA))) {
        LogError("[AimGetter] A: attach failed at +0x%llX", (unsigned long long)kGetWorldOrientationRva);
        s_targetA = nullptr;
    }

    s_targetB = reinterpret_cast<void*>(base + kGetWorldTransformRva);
    if (!sdk->hooking->Attach(handle, s_targetB, reinterpret_cast<void*>(&Hook_GetWorldTransform),
                              reinterpret_cast<void**>(&s_origB))) {
        LogError("[AimGetter] B: attach failed at +0x%llX", (unsigned long long)kGetWorldTransformRva);
        s_targetB = nullptr;
    }

    PatchFireNormaliseCallsite(base);
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

    const uint64_t now = GetTickCount64();
    if (s_lastHeartbeatMs != 0 && now - s_lastHeartbeatMs < 5000) return;
    const uint64_t elapsed = s_lastHeartbeatMs ? (now - s_lastHeartbeatMs) : 5000;
    s_lastHeartbeatMs = now;

    // Which of cam.localOrientation / cam.worldTransform.Orientation carries the
    // head rotation decides whether the world-space peel in lever C conjugates
    // through the dirty or the clean basis, so dump all three every heartbeat.
    {
        void* cam = g_camInstance;
        const int camOff = g_camOrientationOffset;
        float local[4] = {0, 0, 0, 0};
        float world[4] = {0, 0, 0, 0};
        if (cam && camOff >= 0) {
            __try {
                const float* l = reinterpret_cast<const float*>(
                    reinterpret_cast<uint8_t*>(cam) + camOff);
                for (int i = 0; i < 4; ++i) {
                    local[i] = l[i];
                    world[i] = l[i + kWorldOrientationDelta / 4];
                }
            } __except (EXCEPTION_EXECUTE_HANDLER) {}
        }
        LogInfo("[AimGetter] pose: head=(%+.4f,%+.4f,%+.4f,%+.4f) local=(%+.4f,%+.4f,%+.4f,%+.4f) "
                "world=(%+.4f,%+.4f,%+.4f,%+.4f)",
                g_headQuat[0], g_headQuat[1], g_headQuat[2], g_headQuat[3],
                local[0], local[1], local[2], local[3],
                world[0], world[1], world[2], world[3]);
    }

    const uint32_t a = s_callsA.load(std::memory_order_relaxed);
    const uint32_t b = s_callsB.load(std::memory_order_relaxed);
    const uint32_t c = s_callsC.load(std::memory_order_relaxed);
    LogInfo("[AimGetter] heartbeat: mode=%u A=%u (%.1f/s match=%u) B=%u (%.1f/s match=%u) "
            "C=%u (%.1f/s match=%u) overrides=%u",
            s_mode.load(std::memory_order_relaxed),
            a, (a - s_lastCallsA) * 1000.0 / elapsed, s_matchA.load(std::memory_order_relaxed),
            b, (b - s_lastCallsB) * 1000.0 / elapsed, s_matchB.load(std::memory_order_relaxed),
            c, (c - s_lastCallsC) * 1000.0 / elapsed, s_matchC.load(std::memory_order_relaxed),
            s_overrides.load(std::memory_order_relaxed));
    s_lastCallsA = a; s_lastCallsB = b; s_lastCallsC = c;
}

bool AimGetterHook_IsActive() {
    return s_started.load(std::memory_order_acquire);
}
