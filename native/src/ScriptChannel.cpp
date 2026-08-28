// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "ScriptChannel.hpp"
#include "FppCameraWrite.hpp"

#include "ChaseCameraHook.hpp"

#include <RED4ext/RED4ext.hpp>
#include <RED4ext/CString.hpp>
#include <RED4ext/RTTISystem.hpp>
#include <RED4ext/Scripting/Functions.hpp>
#include <RED4ext/Scripting/Utils.hpp>

#include <windows.h>
#include <atomic>
#include <cmath>

#include "AimCompensation.hpp"
#include "SharedState.hpp"
#include "UdpReceiver.hpp"

namespace {

// Bit layout for the `flags` out-param, mirrored in modules/udp.lua. Bit 1 and
// bit 6 are live status; bits 3-5 and bit 7 are one-shot edges that Lua clears
// on consume. Keep both sides in sync when adding new flags.
constexpr uint32_t kFlagCameraActive     = 1u << 1;
constexpr uint32_t kFlagToggleTracking   = 1u << 3;
constexpr uint32_t kFlagCycleMode        = 1u << 4;
constexpr uint32_t kFlagToggleYaw        = 1u << 5;
constexpr uint32_t kFlagRemoteConnection = 1u << 6;
constexpr uint32_t kFlagCycleAdsMode     = 1u << 7;

std::atomic<uint64_t> s_lastPushMs{0};
std::atomic<bool> s_lastPushEnabled{false};
std::atomic<bool> s_lastPushIsAds{false};
std::atomic<float> s_lastPushHeadDegrees{0.0f};
std::atomic<bool> s_chaseCameraActive{false};
std::atomic<bool> s_loggedFirstPush{false};

bool s_toggleTrackingChordWasDown = false;
bool s_cycleModeChordWasDown = false;
bool s_yawModeChordWasDown = false;
bool s_adsModeChordWasDown = false;

// True when the foreground window belongs to this process. The chords below
// are read from GetAsyncKeyState, which is global to the session: without this
// they fire while the player is alt-tabbed into another application.
bool GameWindowHasFocus() {
    const HWND fg = GetForegroundWindow();
    if (!fg) return false;
    DWORD pid = 0;
    GetWindowThreadProcessId(fg, &pid);
    return pid == GetCurrentProcessId();
}

// Polls the standard CameraUnlock chords (Ctrl+Shift+{Y,G,H,U}). Each chord is
// paired with the canonical nav-cluster key as a parallel edge source; either
// firing produces one edge. Neither set can go through CET: registerHotkey
// dispatch crashes before entering Lua on this game build, and the sandbox
// strips LuaJIT FFI so Lua-side GetAsyncKeyState polling is impossible.
struct ChordEdges {
    bool toggleTracking;
    bool cycleMode;
    bool yawMode;
    bool adsMode;
};

ChordEdges ConsumeChordEdges() {
    const bool ctrlDown = ((GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0) ||
                          ((GetAsyncKeyState(VK_LCONTROL) & 0x8000) != 0) ||
                          ((GetAsyncKeyState(VK_RCONTROL) & 0x8000) != 0);
    const bool shiftDown = ((GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0) ||
                           ((GetAsyncKeyState(VK_LSHIFT) & 0x8000) != 0) ||
                           ((GetAsyncKeyState(VK_RSHIFT) & 0x8000) != 0);
    const bool modsDown = ctrlDown && shiftDown;

    const bool toggleDown =
        ((GetAsyncKeyState(VK_END) & 0x8000) != 0) ||
        (modsDown && ((GetAsyncKeyState('Y') & 0x8000) != 0));
    const bool cycleDown =
        ((GetAsyncKeyState(VK_PRIOR) & 0x8000) != 0) ||
        (modsDown && ((GetAsyncKeyState('G') & 0x8000) != 0));
    const bool yawDown =
        ((GetAsyncKeyState(VK_NEXT) & 0x8000) != 0) ||
        (modsDown && ((GetAsyncKeyState('H') & 0x8000) != 0));
    // Insert / Ctrl+Shift+U cycle the aim-down-sights behaviour. U is the next
    // free letter in the T/Y/U/G/H/J cluster after Y, G and H. Ctrl+Shift+T is
    // deliberately NOT used: it was the recenter chord before mods stopped
    // keeping a centre, so it would still fire on muscle memory.
    const bool adsDown =
        ((GetAsyncKeyState(VK_INSERT) & 0x8000) != 0) ||
        (modsDown && ((GetAsyncKeyState('U') & 0x8000) != 0));

    // Latch the physical state even while unfocused, so a key held across the
    // focus boundary is not read as a fresh press the moment the game returns.
    const bool focused = GameWindowHasFocus();

    ChordEdges e{};
    e.toggleTracking = focused && toggleDown && !s_toggleTrackingChordWasDown;
    e.cycleMode      = focused && cycleDown  && !s_cycleModeChordWasDown;
    e.yawMode        = focused && yawDown    && !s_yawModeChordWasDown;
    e.adsMode        = focused && adsDown    && !s_adsModeChordWasDown;
    s_toggleTrackingChordWasDown = toggleDown;
    s_cycleModeChordWasDown      = cycleDown;
    s_yawModeChordWasDown        = yawDown;
    s_adsModeChordWasDown        = adsDown;
    return e;
}

void PollPose(RED4ext::IScriptable*, RED4ext::CStackFrame* aFrame, bool* aOut, int64_t) {
    float* pYaw = nullptr;
    float* pPitch = nullptr;
    float* pRoll = nullptr;
    float* pX = nullptr;
    float* pY = nullptr;
    float* pZ = nullptr;
    uint32_t* pFlags = nullptr;
    RED4ext::GetParameter(aFrame, &pYaw);
    RED4ext::GetParameter(aFrame, &pPitch);
    RED4ext::GetParameter(aFrame, &pRoll);
    RED4ext::GetParameter(aFrame, &pX);
    RED4ext::GetParameter(aFrame, &pY);
    RED4ext::GetParameter(aFrame, &pZ);
    RED4ext::GetParameter(aFrame, &pFlags);
    ++aFrame->code; // ParamEnd

    UdpReceiver_PublishLatest();
    const HeadTrackingState state = g_sharedState.Read();

    uint32_t flags = 0;
    if (state.camera_hook_active && state.enabled && state.applied_frame > 0) {
        flags |= kFlagCameraActive;
    }
    const ChordEdges edges = ConsumeChordEdges();
    if (edges.toggleTracking) flags |= kFlagToggleTracking;
    if (edges.cycleMode)      flags |= kFlagCycleMode;
    if (edges.yawMode)        flags |= kFlagToggleYaw;
    if (edges.adsMode)        flags |= kFlagCycleAdsMode;
    // Live status, not an edge: Lua re-reads it every poll so a user switching
    // between a local OpenTrack instance and a phone on WiFi gets the other
    // smoothing parameter without a game restart.
    if (UdpReceiver_IsRemoteConnection()) flags |= kFlagRemoteConnection;

    if (pYaw)   *pYaw   = state.raw_yaw;
    if (pPitch) *pPitch = state.raw_pitch;
    if (pRoll)  *pRoll  = state.raw_roll;
    if (pX)     *pX     = state.raw_x;
    if (pY)     *pY     = state.raw_y;
    if (pZ)     *pZ     = state.raw_z;
    if (pFlags) *pFlags = flags;

    if (aOut) *aOut = state.raw_timestamp_ms != 0;
}

void PushState(RED4ext::IScriptable*, RED4ext::CStackFrame* aFrame, bool* aOut, int64_t) {
    float yaw = 0.0f, pitch = 0.0f, roll = 0.0f;
    bool enabled = false, isAds = false, propagatorInject = false;
    float qi = 0.0f, qj = 0.0f, qk = 0.0f, qr = 1.0f;
    float positionX = 0.0f, positionY = 0.0f, positionZ = 0.0f, aimDistance = 0.0f;
    bool chaseCamera = false;
    RED4ext::GetParameter(aFrame, &yaw);
    RED4ext::GetParameter(aFrame, &pitch);
    RED4ext::GetParameter(aFrame, &roll);
    RED4ext::GetParameter(aFrame, &enabled);
    RED4ext::GetParameter(aFrame, &isAds);
    RED4ext::GetParameter(aFrame, &qi);
    RED4ext::GetParameter(aFrame, &qj);
    RED4ext::GetParameter(aFrame, &qk);
    RED4ext::GetParameter(aFrame, &qr);
    RED4ext::GetParameter(aFrame, &propagatorInject);
    RED4ext::GetParameter(aFrame, &positionX);
    RED4ext::GetParameter(aFrame, &positionY);
    RED4ext::GetParameter(aFrame, &positionZ);
    RED4ext::GetParameter(aFrame, &aimDistance);
    RED4ext::GetParameter(aFrame, &chaseCamera);
    ++aFrame->code; // ParamEnd

    s_lastPushMs.store(GetTickCount64(), std::memory_order_relaxed);

    // Script values cross a trust boundary: a malformed quat written into
    // shared state reaches the hooks that multiply it into the camera.
    if (!std::isfinite(yaw) || !std::isfinite(pitch) || !std::isfinite(roll) ||
        !std::isfinite(qi) || !std::isfinite(qj) || !std::isfinite(qk) || !std::isfinite(qr) ||
        !std::isfinite(positionX) || !std::isfinite(positionY) ||
        !std::isfinite(positionZ) || !std::isfinite(aimDistance)) {
        s_chaseCameraActive.store(false, std::memory_order_relaxed);
        if (aOut) *aOut = false;
        return;
    }
    const float magSq = qi * qi + qj * qj + qk * qk + qr * qr;
    if (std::abs(yaw) > 720.0f || std::abs(pitch) > 720.0f || std::abs(roll) > 720.0f ||
        magSq < 0.5f || magSq > 2.0f) {
        s_chaseCameraActive.store(false, std::memory_order_relaxed);
        if (aOut) *aOut = false;
        return;
    }

    HeadTrackingState* w = g_sharedState.GetWritable();
    if (!w) {
        if (aOut) *aOut = false;
        return;
    }
    w->yaw = yaw;
    w->pitch = pitch;
    w->roll = roll;
    w->enabled = enabled;
    w->is_ads = isAds;
    w->camera_hook_inject = enabled;
    w->propagator_inject_active = propagatorInject ? 1u : 0u;
    w->quat_i = qi;
    w->quat_j = qj;
    w->quat_k = qk;
    w->quat_r = qr;
    w->position_x = positionX;
    w->position_y = positionY;
    w->position_z = positionZ;
    w->aim_distance = aimDistance;
    w->applied_frame = w->applied_frame + 1;
    w->frame = w->frame + 1;

    // The two readers (render injection, aim peel) both key off the gameplay
    // gate as well, so fold it in here rather than making each of them repeat
    // the same `enabled &&`.
    const bool chaseActive = enabled && chaseCamera;
    s_chaseCameraActive.store(chaseActive, std::memory_order_relaxed);
    if (chaseActive) {
        // Detour the camera publish on the first frame the player is actually
        // in the chase camera, so a session that never drives in third person
        // never gets it.
        ChaseCameraHook_EnsureInstalled();
    }
    s_lastPushEnabled.store(enabled, std::memory_order_relaxed);
    s_lastPushIsAds.store(isAds, std::memory_order_relaxed);
    const float absR = std::abs(qr) > 1.0f ? 1.0f : std::abs(qr);
    s_lastPushHeadDegrees.store(
        static_cast<float>(2.0 * std::acos(absR) * 57.2957795), std::memory_order_relaxed);

    if (!s_loggedFirstPush.exchange(true)) {
        LogInfo("[ScriptChannel] first state push from the CET mod: enabled=%d propInject=%d chaseCam=%d yaw=%.2f pitch=%.2f roll=%.2f",
                enabled ? 1 : 0, propagatorInject ? 1 : 0, chaseCamera ? 1 : 0, yaw, pitch, roll);
    }
    if (aOut) *aOut = true;
}

// The CET half's init result is the single most common answer to a "no head
// tracking" report, and it used to be reachable only through CET's own
// scripting.log - a second file, in a third place, that we had to ask for.
// This lets the Lua mod write its lifecycle lines into the same
// HeadTracking.log the native half uses.
void ScriptLog(RED4ext::IScriptable*, RED4ext::CStackFrame* aFrame,
               void*, int64_t) {
    RED4ext::CString text;
    RED4ext::GetParameter(aFrame, &text);
    ++aFrame->code;
    LogInfo("[CET] %s", text.c_str());
}

void RegisterFunctions() {
    auto* rtti = RED4ext::CRTTISystem::Get();

    auto* poll = RED4ext::CGlobalFunction::Create(
        "HeadTrackingPollPose", "HeadTrackingPollPose", &PollPose);
    poll->flags.isNative = true;
    poll->AddParam("Float", "yaw", true);
    poll->AddParam("Float", "pitch", true);
    poll->AddParam("Float", "roll", true);
    poll->AddParam("Float", "x", true);
    poll->AddParam("Float", "y", true);
    poll->AddParam("Float", "z", true);
    poll->AddParam("Uint32", "flags", true);
    poll->SetReturnType("Bool");
    rtti->RegisterFunction(poll);

    auto* push = RED4ext::CGlobalFunction::Create(
        "HeadTrackingPushState", "HeadTrackingPushState", &PushState);
    push->flags.isNative = true;
    push->AddParam("Float", "yaw");
    push->AddParam("Float", "pitch");
    push->AddParam("Float", "roll");
    push->AddParam("Bool", "enabled");
    push->AddParam("Bool", "isAds");
    push->AddParam("Float", "qi");
    push->AddParam("Float", "qj");
    push->AddParam("Float", "qk");
    push->AddParam("Float", "qr");
    push->AddParam("Bool", "propagatorInject");
    push->AddParam("Float", "positionX");
    push->AddParam("Float", "positionY");
    push->AddParam("Float", "positionZ");
    push->AddParam("Float", "aimDistance");
    push->AddParam("Bool", "chaseCamera");
    push->SetReturnType("Bool");
    rtti->RegisterFunction(push);

    FppCameraWrite_Register(rtti);

    LogInfo("[ScriptChannel] registered the pose state functions");
}

// Registered from the POST-register callback, not the one above. `String` is a
// class type the engine registers alongside everything else, so during the
// register pass CRTTISystem::GetType("String") still returns null, AddParam
// silently drops the parameter, and the function reaches Lua declaring zero
// arguments - every call then fails with "requires 0 parameter(s)". The pose
// functions above only take Float/Bool/Uint32, which are fundamentals present
// from the start, which is why they work where they are.
void RegisterLogFunction() {
    auto* rtti = RED4ext::CRTTISystem::Get();

    auto* scriptLog = RED4ext::CGlobalFunction::Create(
        "HeadTrackingLog", "HeadTrackingLog", &ScriptLog);
    scriptLog->flags.isNative = true;
    if (!scriptLog->AddParam("String", "text")) {
        LogError("[ScriptChannel] String type unavailable - HeadTrackingLog not registered, "
                 "the CET mod's lines will not reach this log");
        return;
    }
    rtti->RegisterFunction(scriptLog);
    LogInfo("[ScriptChannel] registered the script log function");
}

} // namespace

void ScriptChannel_Register() {
    RED4ext::CRTTISystem::Get()->AddRegisterCallback(&RegisterFunctions);
    RED4ext::CRTTISystem::Get()->AddPostRegisterCallback(&RegisterLogFunction);
}

uint64_t ScriptChannel_MsSinceLastPush() {
    const uint64_t last = s_lastPushMs.load(std::memory_order_relaxed);
    if (last == 0) return 0;
    return GetTickCount64() - last;
}

bool ScriptChannel_HasEverPushed() {
    return s_lastPushMs.load(std::memory_order_relaxed) != 0;
}

bool ScriptChannel_LastPushEnabled() {
    return s_lastPushEnabled.load(std::memory_order_relaxed);
}

bool ScriptChannel_LastPushIsAds() {
    return s_lastPushIsAds.load(std::memory_order_relaxed);
}

float ScriptChannel_LastPushHeadDegrees() {
    return s_lastPushHeadDegrees.load(std::memory_order_relaxed);
}

bool ScriptChannel_ChaseCameraActive() {
    return s_chaseCameraActive.load(std::memory_order_relaxed);
}
