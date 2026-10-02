// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
//
// GOG build profiles. Append-only: a game patch adds a profile below, it never
// edits one above. One file per store.
#include "build_profile.h"

namespace builds {

// Game 2.31, EXE 3.0.5294808, built 2025-08-27. The build every RVA in this
// plugin was derived against (Ghidra + runtime capture, see the session notes
// referenced from AGENTS.md).
//
// The Steam 2.31 EXE is the same file byte for byte (MD5
// 9add9693b83dfbae264c449487cea379 on both installs, checked 2026-10-02), so
// this one profile covers both stores; the name says so because it is what a
// Steam player reads in the log. The store-specific code lives in the
// GameServices*.dll beside the EXE, not in the EXE.
extern const BuildProfile kGogProfile_20250827 = {
    "gog-steam-win64-20250827",
    { 0x68AF45EA, 0x04EFC000, 0x039357A5 },
    {
        0x802390,  // GetWorldOrientation
        0x84C968,  // FireNormaliseCall
        0x13DE80,  // NormaliseFn
        0x84AAC8,  // RicochetEffectExecute
        0x84E2D0,  // PhysicalRayExecute
        0x84E376,  // PhysicalRayNormaliseCall
        0x4E8AC7,  // SmartGunCameraCallA
        0x4E8B6F,  // SmartGunCameraCallB
        0x127404,  // CameraPublishFn
        0x4B9D84,  // TargetingRecordUpdate
        0x4E8D68,  // CameraTransformFn
        0x3F90F7,  // CrosshairRaycastCameraReturn
    },
};

}  // namespace builds
