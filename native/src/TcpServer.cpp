// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "TcpServer.hpp"
#include "SharedState.hpp"
#include "AimCompensation.hpp"  // LogInfo/LogWarning/LogError
#include "NativeRunningHook.hpp"
#include "UdpReceiver.hpp"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <thread>
#include <cstdio>
#include <cstring>

#pragma comment(lib, "ws2_32.lib")

namespace {

// Bit layout for the tracking-data "flags" field, mirrored in modules/udp.lua.
// Bits 0-1 are live status; bits 2-5 are one-shot edges that Lua clears on
// consume. Keep both sides in sync when adding new flags.
constexpr uint32_t kFlagHitscanActive   = 1u << 0;
constexpr uint32_t kFlagCameraActive    = 1u << 1;
constexpr uint32_t kFlagRecenter        = 1u << 2;
constexpr uint32_t kFlagToggleTracking  = 1u << 3;
constexpr uint32_t kFlagCycleMode       = 1u << 4;
constexpr uint32_t kFlagToggleYaw       = 1u << 5;

std::atomic<bool> s_running{ false };
std::atomic<bool> s_wsaStarted{ false };
std::atomic<bool> s_loggedProcessedState{ false };
std::atomic<bool> s_loggedBadStateCommand{ false };
SOCKET s_listenSocket = INVALID_SOCKET;
std::thread s_thread;
bool s_recenterKeyWasDown = false;
bool s_toggleTrackingChordWasDown = false;
bool s_cycleModeChordWasDown = false;
bool s_yawModeChordWasDown = false;

// Per-client connection counter, used as the protocol's "seq" field. The
// reader only cares that the value strictly increases between consecutive
// responses so it can discard stale samples.
uint32_t s_seq = 0;


bool HandleStateCommand(const char* buf, size_t len) {
    if (len < 4 || buf[0] != 'G' || buf[1] != ',') return false;
    float yaw = 0, pitch = 0, roll = 0;
    int enabled = 0, isAds = 0;
    int propagatorInject = 0;
    float qi = 0, qj = 0, qk = 0, qr = 1;
    char tmp[192];
    size_t copy = (len < sizeof(tmp) - 1) ? len : sizeof(tmp) - 1;
    std::memcpy(tmp, buf, copy);
    tmp[copy] = '\0';
    int parsed = std::sscanf(tmp, "G,%f,%f,%f,%d,%d,%f,%f,%f,%f,%d",
                             &yaw, &pitch, &roll, &enabled, &isAds,
                             &qi, &qj, &qk, &qr, &propagatorInject);
    if (parsed != 9 && parsed != 10) return false;
    if (!std::isfinite(yaw) || !std::isfinite(pitch) || !std::isfinite(roll) ||
        !std::isfinite(qi) || !std::isfinite(qj) ||
        !std::isfinite(qk) || !std::isfinite(qr)) {
        return false;
    }
    const float magSq = qi*qi + qj*qj + qk*qk + qr*qr;
    if (std::abs(yaw) > 720.0f || std::abs(pitch) > 720.0f || std::abs(roll) > 720.0f ||
        magSq < 0.5f || magSq > 2.0f) {
        return false;
    }
    HeadTrackingState* w = g_sharedState.GetWritable();
    if (!w) return false;
    w->yaw = yaw;
    w->pitch = pitch;
    w->roll = roll;
    w->enabled = enabled != 0;
    w->is_ads = isAds != 0;
    w->camera_hook_inject = enabled != 0;
    w->propagator_inject_active = propagatorInject != 0 ? 1u : 0u;
    w->quat_i = qi;
    w->quat_j = qj;
    w->quat_k = qk;
    w->quat_r = qr;
    w->applied_frame = w->applied_frame + 1;
    w->frame = w->frame + 1;
    if (!s_loggedProcessedState.exchange(true)) {
        LogInfo("[HeadTrackingAim] TCP processed state received: enabled=%d propInject=%d yaw=%.2f pitch=%.2f roll=%.2f",
                enabled != 0, propagatorInject != 0, yaw, pitch, roll);
    }
    return true;
}

// Polls the four standard CameraUnlock chords (Ctrl+Shift+{T,Y,G,H}) plus the
// Home nav-cluster recenter alias. Each chord is paired with the canonical
// nav-cluster key as a parallel edge source; either firing produces one edge.
// LuaJIT FFI is stripped in the CET sandbox on this build, so chord polling
// must happen here in native and be surfaced to CET as bit flags on the
// existing tracking-data TCP response.
struct ChordEdges {
    bool recenter;
    bool toggleTracking;
    bool cycleMode;
    bool yawMode;
};

ChordEdges ConsumeChordEdges() {
    const bool ctrlDown = ((GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0) ||
                          ((GetAsyncKeyState(VK_LCONTROL) & 0x8000) != 0) ||
                          ((GetAsyncKeyState(VK_RCONTROL) & 0x8000) != 0);
    const bool shiftDown = ((GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0) ||
                           ((GetAsyncKeyState(VK_LSHIFT) & 0x8000) != 0) ||
                           ((GetAsyncKeyState(VK_RSHIFT) & 0x8000) != 0);
    const bool modsDown = ctrlDown && shiftDown;

    const bool recenterDown =
        ((GetAsyncKeyState(VK_HOME) & 0x8000) != 0) ||
        (modsDown && ((GetAsyncKeyState('T') & 0x8000) != 0));
    const bool toggleDown =
        ((GetAsyncKeyState(VK_END) & 0x8000) != 0) ||
        (modsDown && ((GetAsyncKeyState('Y') & 0x8000) != 0));
    const bool cycleDown  =
        ((GetAsyncKeyState(VK_PRIOR) & 0x8000) != 0) ||
        (modsDown && ((GetAsyncKeyState('G') & 0x8000) != 0));
    const bool yawDown    =
        ((GetAsyncKeyState(VK_NEXT) & 0x8000) != 0) ||
        (modsDown && ((GetAsyncKeyState('H') & 0x8000) != 0));

    ChordEdges e{};
    e.recenter       = recenterDown && !s_recenterKeyWasDown;
    e.toggleTracking = toggleDown   && !s_toggleTrackingChordWasDown;
    e.cycleMode      = cycleDown    && !s_cycleModeChordWasDown;
    e.yawMode        = yawDown      && !s_yawModeChordWasDown;
    s_recenterKeyWasDown        = recenterDown;
    s_toggleTrackingChordWasDown = toggleDown;
    s_cycleModeChordWasDown     = cycleDown;
    s_yawModeChordWasDown       = yawDown;
    return e;
}

void ServeClient(SOCKET client) {
    char inbuf[512];
    char outbuf[128];

    DWORD recvTimeoutMs = 2000;
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO,
               reinterpret_cast<const char*>(&recvTimeoutMs), sizeof(recvTimeoutMs));

    while (s_running.load(std::memory_order_acquire)) {
        int n = recv(client, inbuf, sizeof(inbuf), 0);
        if (n <= 0) {
            // Either the client closed, our timeout fired, or the listener
            // shutdown is propagating - close and let Accept hand us a new one.
            break;
        }

        // Protocol discriminators (one-byte prefix, comma-separated args):
        //   anything else (traditionally 'G') -> "get latest pose"; reply
        //     with "<seq>,yaw,pitch,roll\r\n" as before.
        // Keep the read loop tight: publish paths must not block the
        // regular 60-120 Hz pose-poll ping-pong.
        if (n >= 2 && inbuf[0] == 'G' && inbuf[1] == ',') {
            if (!HandleStateCommand(inbuf, static_cast<size_t>(n)) &&
                !s_loggedBadStateCommand.exchange(true)) {
                LogWarning("[HeadTrackingAim] TCP processed state parse failed, bytes=%d", n);
            }
        }
        UdpReceiver_PublishLatest();
        HeadTrackingState state = g_sharedState.Read();
        ++s_seq;
        uint32_t flags = 0;
        const bool hasProcessedState = state.enabled && state.applied_frame > 0;
        if (state.camera_hook_active && hasProcessedState)  flags |= kFlagCameraActive;
        const ChordEdges edges = ConsumeChordEdges();
        const bool trackerRecenter = UdpReceiver_TryConsumeRecenterRequest();
        if (edges.recenter || trackerRecenter) flags |= kFlagRecenter;
        if (edges.toggleTracking) flags |= kFlagToggleTracking;
        if (edges.cycleMode)      flags |= kFlagCycleMode;
        if (edges.yawMode)        flags |= kFlagToggleYaw;
        int written = std::snprintf(outbuf, sizeof(outbuf),
                                    "%u,%.4f,%.4f,%.4f,%u,%.4f,%.4f,%.4f\r\n",
                                    s_seq,
                                    state.raw_yaw,
                                    state.raw_pitch,
                                    state.raw_roll,
                                    flags,
                                    state.raw_x,
                                    state.raw_y,
                                    state.raw_z);
        if (written <= 0) continue;

        int sent = 0;
        while (sent < written) {
            int s = send(client, outbuf + sent, written - sent, 0);
            if (s == SOCKET_ERROR) {
                sent = -1;
                break;
            }
            sent += s;
        }
        if (sent < 0) break;
    }

    closesocket(client);
}

void AcceptLoop() {
    while (s_running.load(std::memory_order_acquire)) {
        sockaddr_in from{};
        int fromLen = sizeof(from);
        SOCKET client = accept(s_listenSocket,
                               reinterpret_cast<sockaddr*>(&from), &fromLen);
        if (client == INVALID_SOCKET) {
            int err = WSAGetLastError();
            if (!s_running.load(std::memory_order_acquire)) break;
            if (err == WSAEINTR || err == WSAESHUTDOWN || err == WSAENOTSOCK) break;
            // Transient - back off briefly then retry.
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            continue;
        }
        ServeClient(client);
    }
}

} // namespace

bool TcpServer_Start(uint16_t port) {
    if (s_running.load()) return true;

    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        LogError("[HeadTrackingAim] TCP WSAStartup failed");
        return false;
    }
    s_wsaStarted.store(true);

    s_listenSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s_listenSocket == INVALID_SOCKET) {
        LogError("[HeadTrackingAim] TCP socket() failed, WSA=%d", WSAGetLastError());
        WSACleanup();
        s_wsaStarted.store(false);
        return false;
    }

    BOOL reuse = TRUE;
    setsockopt(s_listenSocket, SOL_SOCKET, SO_REUSEADDR,
               reinterpret_cast<const char*>(&reuse), sizeof(reuse));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

    if (bind(s_listenSocket, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == SOCKET_ERROR) {
        int err = WSAGetLastError();
        LogError("[HeadTrackingAim] TCP bind(127.0.0.1:%u) failed, WSA=%d", port, err);
        closesocket(s_listenSocket);
        s_listenSocket = INVALID_SOCKET;
        WSACleanup();
        s_wsaStarted.store(false);
        return false;
    }

    if (listen(s_listenSocket, 4) == SOCKET_ERROR) {
        int err = WSAGetLastError();
        LogError("[HeadTrackingAim] TCP listen(127.0.0.1:%u) failed, WSA=%d", port, err);
        closesocket(s_listenSocket);
        s_listenSocket = INVALID_SOCKET;
        WSACleanup();
        s_wsaStarted.store(false);
        return false;
    }

    s_running.store(true, std::memory_order_release);
    s_thread = std::thread(AcceptLoop);
    LogInfo("[HeadTrackingAim] TCP server listening on 127.0.0.1:%u (CET reads here)", port);
    return true;
}

void TcpServer_Stop() {
    if (!s_running.exchange(false)) {
        // Not running.
    }

    if (s_listenSocket != INVALID_SOCKET) {
        shutdown(s_listenSocket, SD_BOTH);
        closesocket(s_listenSocket);
        s_listenSocket = INVALID_SOCKET;
    }

    if (s_thread.joinable()) {
        s_thread.join();
    }

    if (s_wsaStarted.exchange(false)) {
        WSACleanup();
    }
    LogInfo("[HeadTrackingAim] TCP server stopped");
}
