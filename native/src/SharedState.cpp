#include "SharedState.hpp"
#include <cmath>

// Global instance
SharedState g_sharedState;

// Last known-good state, used when a read would otherwise hand back a
// value damaged by a torn read (NaN/Inf would otherwise propagate into
// rotation math and corrupt the bullet direction). Start at identity
// quaternion so a pre-tracking read doesn't inject garbage rotation.
static HeadTrackingState s_lastGoodState = []{
    HeadTrackingState s{};
    s.quat_r = 1.0f;
    return s;
}();

static bool IsSane(const HeadTrackingState& s) {
    auto finite = [](float v) { return std::isfinite(v); };
    // Processed pose (Lua -> native) and ADS scaling.
    if (!finite(s.yaw) || !finite(s.pitch) || !finite(s.roll) || !finite(s.ads_scale)) return false;
    // Raw pose (UDP -> native) is what the aim hook reads directly. Sanitise
    // it here so a poison-pill UDP packet that slipped past UdpReceiver's
    // boundary check (or a torn read of those fields) can't propagate NaN
    // into RotateVector and corrupt bullet direction.
    if (!finite(s.raw_yaw) || !finite(s.raw_pitch) || !finite(s.raw_roll)) return false;
    // Quaternion fields used by the camera hook for the view-matrix injection
    // and SNAP-CLEAN restore. ApplyQuatToMatrix3x3 of a NaN quat produces a
    // NaN view matrix that freezes/garbles the render.
    if (!finite(s.quat_i) || !finite(s.quat_j) || !finite(s.quat_k) || !finite(s.quat_r)) return false;
    if (!finite(s.restore_quat_i) || !finite(s.restore_quat_j) ||
        !finite(s.restore_quat_k) || !finite(s.restore_quat_r)) return false;
    // Yaw/pitch/roll are degrees, not radians - a reading outside ±720 is
    // almost certainly a torn-read artefact, not a real head pose.
    if (std::abs(s.yaw) > 720.0f || std::abs(s.pitch) > 720.0f || std::abs(s.roll) > 720.0f) return false;
    if (std::abs(s.raw_yaw) > 720.0f || std::abs(s.raw_pitch) > 720.0f || std::abs(s.raw_roll) > 720.0f) return false;
    return true;
}

SharedState::~SharedState() {
    Shutdown();
}

bool SharedState::Init() {
    // Try to open existing shared memory (CET Lua should create it)
    m_hMapFile = OpenFileMappingA(
        FILE_MAP_ALL_ACCESS,
        FALSE,
        SHARED_MEM_NAME
    );

    if (m_hMapFile == nullptr) {
        // CET hasn't created it yet - create it ourselves
        // CET will open this when it initializes
        m_hMapFile = CreateFileMappingA(
            INVALID_HANDLE_VALUE,
            nullptr,
            PAGE_READWRITE,
            0,
            static_cast<DWORD>(SHARED_MEM_SIZE),
            SHARED_MEM_NAME
        );

        if (m_hMapFile == nullptr) {
            return false;
        }
    }

    // Map view of file
    m_pState = static_cast<HeadTrackingState*>(
        MapViewOfFile(
            m_hMapFile,
            FILE_MAP_ALL_ACCESS,
            0,
            0,
            SHARED_MEM_SIZE
        )
    );

    if (m_pState == nullptr) {
        CloseHandle(m_hMapFile);
        m_hMapFile = nullptr;
        return false;
    }

    return true;
}

void SharedState::Shutdown() {
    if (m_pState != nullptr) {
        UnmapViewOfFile(m_pState);
        m_pState = nullptr;
    }

    if (m_hMapFile != nullptr) {
        CloseHandle(m_hMapFile);
        m_hMapFile = nullptr;
    }
}

HeadTrackingState SharedState::Read() const {
    if (m_pState == nullptr) {
        return s_lastGoodState;
    }

    // Single writer (CET Lua) / single reader (us). Read twice and compare
    // the frame counter - if it changes mid-read we caught a tear, so retry
    // once then fall back to the last known-good reading.
    HeadTrackingState first = *m_pState;
    if (first.frame == m_pState->frame && IsSane(first)) {
        s_lastGoodState = first;
        return first;
    }

    HeadTrackingState second = *m_pState;
    if (second.frame == m_pState->frame && IsSane(second)) {
        s_lastGoodState = second;
        return second;
    }

    return s_lastGoodState;
}
