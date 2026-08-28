// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <RED4ext/Api/v1/PluginHandle.hpp>
#include <RED4ext/Api/v1/Sdk.hpp>
#include <RED4ext/ISerializable.hpp>  // pulls IScriptable definition
#include <atomic>
#include <cstdint>

namespace RED4ext { struct IScriptable; }

// Register a per-frame RED4ext GameState callback for the Running state.
// Its sole job in phase 1 is to fire every frame, bump a SharedState
// counter, and log its rate so we can confirm the native hook is alive
// and fires at frame cadence.
bool NativeRunningHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
void NativeRunningHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);

// Invoke entICameraComponent::SetLocalOrientation on the local player's
// FPP camera via the RED4ext CRTTI call chain. Returns true on success.
// SEH-wrapped internally so any engine-side fault is caught.
//
// NOT safe to call from the render-pipeline hook - scripted dispatch

// Render-pipeline-safe cam restore: writes 4 floats directly into the
// cached cam instance at the cached orientation offset. No scripted
// dispatch, no RTTI, no lock interaction - just a 16-byte memcpy.
//
// Returns true on success, false if either the cam pointer or the
// orientation offset has not been discovered yet (both are populated
// lazily from NativeRunningHook::OnUpdate's discovery pass).
//
// Both pointers get cached on the first tick where the CRTTI walk
// resolves AND the orientation scan finds a match. From that point on

// SHM-free pre-render coordination. NativeRunningHook (runs in the
// main-thread OnUpdate context where SHM access is proven safe) polls
// the SHM pending flag and mirrors it into these atomics. The pre-render
// hook then reads ONLY these atomics - never touches shared memory -
// because SHM access from inside the render hook has crashed the game
// repeatedly, even on a single read.
//
// The pre-render hook inlines its consume logic against THESE global
// atomics directly - not via a function call - because even a single
// cross-TU call (including a tiny atomic-reader) from inside the hook
// crashes the game. Passthrough + one function call to our own DLL's
// code = consistent crash. Passthrough with no DLL-internal calls =
// stable. So the consume path is inlined in CameraHook.cpp, poking
// context.

// Continuously-mirrored head quat from SHM. OnUpdate refreshes this from
// shared_mem.state.quat_{i,j,k,r} every tick. Read by the render-pipeline
// by AimProviderHook, AimGetterHook and CamPropagatorHook.
extern float                  g_headQuat[4];

// Processed head translation in camera-local metres (x right, y forward,
// z up), mirrored beside g_headQuat and gated the same way. The chase-camera
// injection needs it on the render thread, where touching shared memory has
// crashed the game.
extern float                  g_headPos[3];

// Live clean-aim hit distance, mirrored beside g_headPos and gated the same
// way. The shot path pairs it with g_headPos to converge rounds on the point
// the position-compensated reticle marks; reading it from shared memory there
// meant a whole-struct copy and its sanity walk per pellet.
extern float                  g_aimDistance;

// Diagnostic capture: on first restore the pre-render hook stores the
// camState pointer (4th arg to the hooked function) so OnUpdate can
// later log it - LogInfo cannot be called from inside the hook body
// (even dormant cross-TU calls in the hook function change MSVC codegen
// enough to crash the trampoline). OnUpdate drains this by reading /
// clearing it.



// Pointer and offset for the raw cam-orientation memory write. Both
// populated lazily by OnUpdate when CRTTI + ScanOrientationOffset have
// run. Null / -1 until then, in which case the hook must skip.
extern RED4ext::IScriptable* g_camInstance;
extern int                    g_camOrientationOffset;

// Legacy staging helpers (still used by OnUpdate to keep the write-

// Rolling ring of recent pre-render captures. Hot path in CameraHook
// pre-render writes one entry per call; OnUpdate reads on click events
// and dumps the whole ring. Exposed via raw globals (no cross-TU calls
// from inside the hook - those have crashed the trampoline before).
struct CamRingEntry {
    void* camStatePtr;
    float quats[11][4];      // 11 candidate offsets, [i,j,k,r]
    uint64_t writeSeq;       // monotonic - lets reader spot torn slots
};
constexpr size_t kCamRingSize = 64;
extern CamRingEntry          g_camRing[kCamRingSize];
extern std::atomic<uint64_t> g_camRingWriteSeq;  // total writes; modulo gives slot
// Indexed identically to camera-shaped offset list in OnUpdate; keep
// in sync if the offset list changes.
extern const size_t          kCamRingOffsets[11];
