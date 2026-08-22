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
extern const BuildProfile kGogProfile_20250827 = {
    "gog-win64-20250827",
    { 0x68AF45EA, 0x04EFC000, 0x039357A5 },
    {
        0x1D8558,  // Propagator
        0x802390,  // GetWorldOrientation
        0x1D92A0,  // GetWorldTransform
        0x84C968,  // FireNormaliseCall
        0x13DE80,  // NormaliseFn
        0x84AAC8,  // RicochetEffectExecute
        0x84E2D0,  // PhysicalRayExecute
        0x84E376,  // PhysicalRayNormaliseCall
    },
};

}  // namespace builds
