#pragma once
#include <cmath>
#include <cstdint>

// Rotate a 3D vector by yaw and pitch (degrees). Cyberpunk coords: Y-forward, Z-up.
inline void RotateVector(float& x, float& y, float& z, float yawDeg, float pitchDeg) {
    constexpr float DEG_TO_RAD = 3.14159265358979323846f / 180.0f;

    float yaw = yawDeg * DEG_TO_RAD;
    float pitch = pitchDeg * DEG_TO_RAD;

    float cy = std::cos(yaw);
    float sy = std::sin(yaw);
    float cp = std::cos(pitch);
    float sp = std::sin(pitch);

    float x1 = x * cy - y * sy;
    float y1 = x * sy + y * cy;
    float z1 = z;

    x = x1;
    y = y1 * cp - z1 * sp;
    z = y1 * sp + z1 * cp;
}

inline bool IsNormalizedDirection(float x, float y, float z) {
    float mag = std::sqrt(x * x + y * y + z * z);
    return mag > 0.9f && mag < 1.1f;
}

void LogInfo(const char* format, ...);
void LogWarning(const char* format, ...);
void LogError(const char* format, ...);
