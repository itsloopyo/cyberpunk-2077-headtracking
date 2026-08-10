// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "UdpReceiver.hpp"
#include "SharedState.hpp"
#include "AimCompensation.hpp"

#include <cameraunlock/protocol/udp_receiver.h>

#include <atomic>
#include <string>

namespace {

cameraunlock::UdpReceiver s_receiver;
std::atomic<bool> s_started{false};
int64_t s_lastPublishedTimestamp = 0;

} // namespace

bool UdpReceiver_Start(uint16_t port) {
    if (s_started.exchange(true)) return true;

    s_receiver.SetLog([](const std::string& message) {
        LogInfo("[HeadTrackingAim] UDP receiver: %s", message.c_str());
    });

    const bool bound = s_receiver.Start(port);
    if (bound) {
        LogInfo("[HeadTrackingAim] UDP receiver listening on port %u", port);
    }
    return bound || s_receiver.IsRetrying();
}

void UdpReceiver_Stop() {
    if (!s_started.exchange(false)) return;

    s_receiver.Stop();
    s_lastPublishedTimestamp = 0;
    LogInfo("[HeadTrackingAim] UDP receiver stopped");
}

void UdpReceiver_PublishLatest() {
    const int64_t timestamp = s_receiver.GetLastReceiveTimestamp();
    if (timestamp == 0 || timestamp == s_lastPublishedTimestamp) return;

    float yaw = 0.0f;
    float pitch = 0.0f;
    float roll = 0.0f;
    float x = 0.0f;
    float y = 0.0f;
    float z = 0.0f;
    if (!s_receiver.GetRotation(yaw, pitch, roll) ||
        !s_receiver.GetPosition(x, y, z)) {
        return;
    }

    HeadTrackingState* state = g_sharedState.GetWritable();
    if (state == nullptr) return;

    state->raw_yaw = yaw;
    state->raw_pitch = pitch;
    state->raw_roll = roll;
    state->raw_x = x * 100.0f;
    state->raw_y = y * 100.0f;
    state->raw_z = z * 100.0f;
    state->raw_timestamp_ms = GetTickCount64();
    std::atomic_thread_fence(std::memory_order_release);
    state->raw_frame = state->raw_frame + 1;
    s_lastPublishedTimestamp = timestamp;
}

bool UdpReceiver_TryConsumeRecenterRequest() {
    return s_receiver.TryConsumeRecenterRequest();
}
