// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once
#include <windows.h>
#include <cstdint>

// Shared state structure - must match CET Lua FFI definition exactly.
// Field order, sizes and padding must be identical in aim.lua's ffi.cdef.
//
// Main sections:
//   1. Lua -> native (processed pose): the smoothed, clamped, signed head
//      rotation Lua writes into cam.localOrientation, mirrored for the
//      native hooks that peel it back off the aim.
//   2. native -> Lua (raw UDP pose): the C++ UDP receiver writes raw
//      OpenTrack values as they arrive.
struct HeadTrackingState {
    // ------------------------------------------------------------------
    // Section 1: Lua -> native (processed pose)
    // ------------------------------------------------------------------
    float yaw;                  // processed yaw, degrees (sign matches camera application)
    float pitch;                // processed pitch, degrees
    float roll;                 // processed roll, degrees
    bool  enabled;              // tracking allowed this frame (gates compensation + view injection)
    bool  is_ads;               // weapon aim-down-sights state
    uint8_t pad0[2];
    uint32_t frame;             // incremented each Lua write (sync / liveness)
    float ads_scale;            // reserved ADS effect multiplier

    // Head rotation as a quaternion (i,j,k,r). Lua writes this so C++ can
    // apply it directly to the view matrix without recomputing from Euler
    // (avoids any axis-convention drift between the two sides). Expected
    // to be unit-length; zero quaternion means "no data yet - skip".
    float quat_i;
    float quat_j;
    float quat_k;
    float quat_r;
    uint32_t applied_frame;     // bumps when Lua updates the quat fields above

    // ------------------------------------------------------------------
    // Section 2: native -> Lua (raw UDP-received pose from OpenTrack)
    // ------------------------------------------------------------------
    float    raw_yaw;
    float    raw_pitch;
    float    raw_roll;
    float    raw_x;              // OpenTrack lateral, cm (positive = right)
    float    raw_y;              // OpenTrack vertical, cm (positive = up)
    float    raw_z;              // OpenTrack longitudinal, cm (positive = forward)
    uint32_t raw_frame;          // bumps on every received UDP packet
    uint64_t raw_timestamp_ms;   // GetTickCount64() at receive time

    // ------------------------------------------------------------------
    // Section 4: native -> Lua (Running::OnUpdate hook status)
    // ------------------------------------------------------------------
    // C++ registers a RED4ext Running state OnUpdate callback. Each fire
    // bumps this counter. Used to prove the native per-frame hook is
    // actually firing and to time it against Lua's own onUpdate for the
    // pre-render snap-restore work.
    uint32_t native_running_frame;  // increments every Running::OnUpdate fire

    // ------------------------------------------------------------------
    // Section 9: aim-provider decouple (AimProviderHook)
    // ------------------------------------------------------------------
    // The shot asks an entIOrientationProvider for its launch orientation;
    // for the player that answer is the camera orientation, head rotation
    // and all. The native hook peels the head rotation off that answer in
    // the caller's own buffer, so bullets follow the mouse while the view
    // keeps following the head - per pellet, so automatic fire decouples
    // too, and with no camera state touched there is nothing to restore.
    //
    // provider_mode (Lua -> native):
    //   0 off (instrument only)  1 peel, camera-match gated (ship)
    //   2 peel while LMB held    3 peel always    4 double the head rotation
    // Modes 2-4 are diagnostics.
    uint32_t provider_hook_active;
    uint32_t provider_mode;
    uint32_t provider_calls;
    uint32_t provider_overrides;

    // ------------------------------------------------------------------
    // Section 10: aim-getter decouple (AimGetterHook)
    // ------------------------------------------------------------------
    // Same idea as section 9 for vanilla hitscan weapons, which never build a
    // projectile and so never ask an orientation provider. They call for the
    // camera instead and get the answer in their own buffer - rewriting that
    // buffer decouples the round with no camera state touched.
    //
    // aim_getter_mode (Lua -> native):
    //   0 off   1 instrument only   2 peel via +0x802390 (GetWorldOrientation)
    //   4 peel via +0x84C968 (the weapon-fire routine's Normalize(target - muzzle))
    //   5 fixed test yaw on +0x802390
    uint32_t aim_getter_mode;
    uint32_t aim_getter_calls_a;
    uint32_t aim_getter_calls_c;
    uint32_t aim_getter_overrides;

    // Processed camera translation and the live clean-aim hit distance. The
    // projectile orientation hook uses these to converge rounds on the same
    // world point as the position-compensated reticle.
    float position_x;
    float position_y;
    float position_z;
    float aim_distance;
};

// Shared memory name - must match CET Lua code
constexpr const char* SHARED_MEM_NAME = "HeadTrackingAimState";
constexpr size_t SHARED_MEM_SIZE = sizeof(HeadTrackingState);

static_assert(sizeof(HeadTrackingState) == 136,
    "HeadTrackingState layout changed - update modules/aim.lua cdef to match");

class SharedState {
public:
    SharedState() = default;
    ~SharedState();

    // Initialize shared memory mapping (opens existing or creates new)
    bool Init();

    // Clean up resources
    void Shutdown();

    // Read current state from shared memory
    // Returns default state if not available
    HeadTrackingState Read() const;

    // Direct writable pointer for the native UDP receiver. Returns nullptr if
    // shared memory is not yet mapped. The receiver thread is the only writer
    // of the raw_* fields; no other writer touches them.
    HeadTrackingState* GetWritable() { return m_pState; }

    // Check if shared memory is available
    bool IsAvailable() const { return m_pState != nullptr; }

private:
    HANDLE m_hMapFile = nullptr;
    HeadTrackingState* m_pState = nullptr;
};

// Global instance
extern SharedState g_sharedState;
