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
// and fires at frame cadence. Phase 2 will use the same callback to
// write head-rotated cam.localOrientation back after a SNAP-CLEAN shot,
// killing the one-frame visual flash that the Lua-only path cannot fix.
bool NativeRunningHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
void NativeRunningHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);

// Invoke entICameraComponent::SetLocalOrientation on the local player's
// FPP camera via the RED4ext CRTTI call chain. Returns true on success.
// SEH-wrapped internally so any engine-side fault is caught.
//
// NOT safe to call from the render-pipeline hook - scripted dispatch
// from inside that hook crashes the game. Use NativeCamRestore_DirectWrite
// from there instead.
bool NativeCamRestore_Invoke(float qi, float qj, float qk, float qr);

// Render-pipeline-safe cam restore: writes 4 floats directly into the
// cached cam instance at the cached orientation offset. No scripted
// dispatch, no RTTI, no lock interaction - just a 16-byte memcpy.
//
// Returns true on success, false if either the cam pointer or the
// orientation offset has not been discovered yet (both are populated
// lazily from NativeRunningHook::OnUpdate's discovery pass).
//
// Both pointers get cached on the first SNAP-CLEAN where the CRTTI walk
// resolves AND the orientation scan finds a match. From that point on
// this function is O(1) with a single cache miss and a cache-line write.
bool NativeCamRestore_DirectWrite(float qi, float qj, float qk, float qr);

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
// the same globals that NativePreRender_Stage writes from the safe
// context.
extern std::atomic<uint32_t> g_preRenderPendingSeq;   // producer: OnUpdate. consumer: hook. 0 = nothing staged.
extern std::atomic<uint32_t> g_preRenderConsumedSeq;  // consumer-only: hook. last seq already applied.
extern std::atomic<uint64_t> g_preRenderStagedMs;     // GetTickCount64 timestamp for the staged quat.
extern float                  g_preRenderQuat[4];      // written by OnUpdate BEFORE bumping PendingSeq; read by hook.
extern float                  g_preRenderCleanQuat[4]; // camera orientation at the moment SNAP-CLEAN was staged.
extern std::atomic<bool>      g_preRenderCleanQuatValid;

// Continuously-mirrored head quat from SHM. OnUpdate refreshes this from
// shared_mem.state.quat_{i,j,k,r} every tick. Read by the render-pipeline
// hook on SNAP-CLEAN frames to rotate outMatrix's cached forward vectors
// by the head delta - this fixes the one-frame render flash caused by the
// cam being momentarily clean while bullets are computed.
extern float                  g_headQuat[4];

// Diagnostic capture: on first restore the pre-render hook stores the
// camState pointer (4th arg to the hooked function) so OnUpdate can
// later log it - LogInfo cannot be called from inside the hook body
// (even dormant cross-TU calls in the hook function change MSVC codegen
// enough to crash the trampoline). OnUpdate drains this by reading /
// clearing it.
extern std::atomic<void*> g_diagCamStatePtr;
extern std::atomic<bool>  g_diagCamStateCaptured;

// Per-click camState dump request. SetLocalOrientationHook sets true on
// every LMB click (caller +0x665323); NativeRunningHook OnUpdate dumps a
// short summary of camState's camera-shaped offsets and clears the flag.
// Read-only - never writes to camState.
extern std::atomic<bool>  g_clickDumpRequested;

// Also captures the outMatrix pointer AFTER s_originalFn has written
// it. Read-only from the hook (no write post-call - that crashed the
// game). OnUpdate dumps both the pointer and a 4x4-ish block of
// contents so we can identify whether outMatrix is a view matrix or
// some intermediate struct.
extern std::atomic<void*> g_diagOutMatrixPtr;

// Pointer and offset for the raw cam-orientation memory write. Both
// populated lazily by OnUpdate when CRTTI + ScanOrientationOffset have
// run. Null / -1 until then, in which case the hook must skip.
extern RED4ext::IScriptable* g_camInstance;
extern int                    g_camOrientationOffset;

// Legacy staging helpers (still used by OnUpdate to keep the write-
// side side-effects grouped in one place). Equivalent inline logic in
// the render hook replaces the corresponding consume helper.
void NativePreRender_Stage(float qi, float qj, float qk, float qr, uint32_t req_seq);
uint32_t NativePreRender_GetStagedReqSeq();

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
