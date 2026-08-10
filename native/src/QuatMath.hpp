// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

// =============================================================================
// Shared quaternion math for the native hooks
// =============================================================================
//
// Every hook that peels or composes head rotation needs the Hamilton product,
// and each one used to carry its own byte-identical copy (AimGetterHook,
// AimProviderHook, CamPropagatorHook, ShotEntryProbe, ShotSnapHook). Five
// copies of the sign-sensitive composition the whole mod's correctness rests
// on is exactly the shape where one edited copy silently diverges, so it lives
// here once.
//
// Component order is (x, y, z, w) == REDengine's (i, j, k, r): the imaginary
// parts first, real part last. This matches the layout the engine's quaternion
// slots are read from and written to in memory, so a raw float[4] from the
// game can be passed straight through.
// =============================================================================

namespace quatmath {

/// Hamilton product o = a * b, applying b's rotation first and then a's.
inline void QuatMul(float ax, float ay, float az, float aw,
                    float bx, float by, float bz, float bw,
                    float& ox, float& oy, float& oz, float& ow) {
    ox = aw*bx + ax*bw + ay*bz - az*by;
    oy = aw*by - ax*bz + ay*bw + az*bx;
    oz = aw*bz + ax*by - ay*bx + az*bw;
    ow = aw*bw - ax*bx - ay*by - az*bz;
}

}  // namespace quatmath
