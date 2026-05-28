#include "UdpReceiver.hpp"
#include "SharedState.hpp"
#include "AimCompensation.hpp"  // for LogInfo/Warning/Error

#include <winsock2.h>
#include <ws2tcpip.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <thread>
#include <cstring>

#pragma comment(lib, "ws2_32.lib")

namespace {

std::atomic<bool> s_running{ false };
std::atomic<bool> s_wsaStarted{ false };
SOCKET s_socket = INVALID_SOCKET;
std::thread s_thread;
uint16_t s_port = 0;

// Retry state. Active when the initial bind failed and we're still trying
// to acquire the port from a conflicting process.
std::atomic<bool> s_retrying{ false };
std::thread s_retryThread;

constexpr int kRetryIntervalMs = 5000;
constexpr int kRetryLogIntervalMs = 30000;

// OpenTrack wire format: 6 IEEE-754 little-endian doubles (48 bytes total):
// [ x, y, z, yaw, pitch, roll ]. We only consume the rotation triple.
constexpr size_t kOpenTrackPacketBytes = 48;

void ReceiverLoop() {
    uint8_t buffer[64];
    uint32_t seq = 0;

    while (s_running.load(std::memory_order_acquire)) {
        sockaddr_in from{};
        int fromLen = sizeof(from);

        int n = recvfrom(s_socket,
                         reinterpret_cast<char*>(buffer), sizeof(buffer),
                         0,
                         reinterpret_cast<sockaddr*>(&from), &fromLen);

        if (n == SOCKET_ERROR) {
            int err = WSAGetLastError();
            if (err == WSAEINTR || err == WSAESHUTDOWN) {
                break; // clean shutdown path
            }
            if (!s_running.load(std::memory_order_acquire)) break;
            // Transient error (e.g. WSAECONNRESET from a stale sender on
            // Windows); log once at debug level and keep going.
            LogWarning("[HeadTrackingAim] UDP recvfrom error %d", err);
            continue;
        }

        if (n != static_cast<int>(kOpenTrackPacketBytes)) {
            // Not an OpenTrack packet; ignore.
            continue;
        }

        double vals[6];
        std::memcpy(vals, buffer, sizeof(vals));

        // Boundary validation: OpenTrack rotation values are degrees in
        // [-180, +180] in normal use. A non-finite or absurd value reaching
        // SharedState would propagate through the aim hook's RotateVector
        // (sin/cos of NaN/Inf is NaN) and corrupt bullet direction in the
        // game. Drop the packet rather than write poison.
        if (!std::isfinite(vals[3]) || !std::isfinite(vals[4]) || !std::isfinite(vals[5]) ||
            std::abs(vals[3]) > 720.0 ||
            std::abs(vals[4]) > 720.0 ||
            std::abs(vals[5]) > 720.0) {
            continue;
        }
        // Position triple: OpenTrack sends cm by default. Reject non-finite
        // and absurd magnitudes (> 10m) the same way we do for rotation.
        if (!std::isfinite(vals[0]) || !std::isfinite(vals[1]) || !std::isfinite(vals[2]) ||
            std::abs(vals[0]) > 1000.0 ||
            std::abs(vals[1]) > 1000.0 ||
            std::abs(vals[2]) > 1000.0) {
            continue;
        }

        HeadTrackingState* state = g_sharedState.GetWritable();
        if (state == nullptr) {
            continue;
        }

        // Write payload first, then bump raw_frame last. Lua readers compare
        // raw_frame against the value they observed before reading the pose;
        // a stable frame means the pose wasn't torn mid-update.
        state->raw_yaw   = static_cast<float>(vals[3]);
        state->raw_pitch = static_cast<float>(vals[4]);
        state->raw_roll  = static_cast<float>(vals[5]);
        state->raw_x     = static_cast<float>(vals[0]);
        state->raw_y     = static_cast<float>(vals[1]);
        state->raw_z     = static_cast<float>(vals[2]);
        state->raw_timestamp_ms = GetTickCount64();
        std::atomic_thread_fence(std::memory_order_release);
        state->raw_frame = ++seq;
    }
}

// Attempts a single bind on the given port. WSAStartup must already have
// succeeded. On success populates s_socket, sets s_running, spawns the
// receiver thread, and returns true. On failure returns false with no
// side effects (s_socket left INVALID_SOCKET, s_running false).
bool TryBindOnce(uint16_t port) {
    SOCKET sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == INVALID_SOCKET) {
        return false;
    }

    BOOL reuse = TRUE;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR,
               reinterpret_cast<const char*>(&reuse), sizeof(reuse));

    DWORD timeoutMs = 500;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
               reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    // Bind to INADDR_ANY so packets arriving on the LAN interface also reach
    // us - the common setup is OpenTrack running on a phone / second PC and
    // sending UDP across the LAN. The upside of loopback-only was that a LAN
    // attacker couldn't jitter your view; the cost was silently dropping the
    // most common real-world tracker topology. Anyone on your LAN who can
    // already craft OpenTrack-format UDP at your machine can at worst wiggle
    // your camera, so we take the tradeoff.
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == SOCKET_ERROR) {
        closesocket(sock);
        return false;
    }

    s_socket = sock;
    s_port = port;
    s_running.store(true, std::memory_order_release);
    s_thread = std::thread(ReceiverLoop);
    return true;
}

// Background thread. Retries TryBindOnce every kRetryIntervalMs until either
// it succeeds or s_retrying is cleared by Stop(). Logs the first failure
// (from the caller) and then a "still waiting" line every kRetryLogIntervalMs.
void RetryLoop(uint16_t port) {
    const int sleepSlices = kRetryIntervalMs / 100;
    int attempts = 0;
    int elapsedMs = 0;
    int nextLogAtMs = kRetryLogIntervalMs;

    while (s_retrying.load(std::memory_order_acquire)) {
        for (int i = 0; i < sleepSlices; ++i) {
            if (!s_retrying.load(std::memory_order_acquire)) return;
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }

        if (!s_retrying.load(std::memory_order_acquire)) return;
        ++attempts;
        elapsedMs += kRetryIntervalMs;

        if (TryBindOnce(port)) {
            LogInfo("[HeadTrackingAim] UDP receiver bound on 0.0.0.0:%u after %d retries",
                    port, attempts);
            s_retrying.store(false, std::memory_order_release);
            return;
        }

        if (elapsedMs >= nextLogAtMs) {
            LogWarning("[HeadTrackingAim] Still waiting for UDP port %u (%ds elapsed); close any conflicting tracker to resume",
                       port, elapsedMs / 1000);
            nextLogAtMs += kRetryLogIntervalMs;
        }
    }
}

} // namespace

bool UdpReceiver_Start(uint16_t port) {
    if (s_running.load()) return true;
    if (s_retrying.load()) return true;

    if (!s_wsaStarted.load()) {
        WSADATA wsa{};
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
            LogError("[HeadTrackingAim] WSAStartup failed");
            return false;
        }
        s_wsaStarted.store(true);
    }

    if (TryBindOnce(port)) {
        LogInfo("[HeadTrackingAim] UDP receiver listening on 0.0.0.0:%u", port);
        return true;
    }

    int err = WSAGetLastError();
    LogError("[HeadTrackingAim] Failed to bind UDP port %u (WSA=%d) -- will retry every %ds; close any conflicting tracker to resume",
             port, err, kRetryIntervalMs / 1000);
    s_retrying.store(true, std::memory_order_release);
    s_retryThread = std::thread(RetryLoop, port);
    return true;
}

void UdpReceiver_Stop() {
    if (s_retrying.exchange(false)) {
        if (s_retryThread.joinable()) {
            s_retryThread.join();
        }
    }

    if (!s_running.exchange(false)) {
        // Not running, but WSA may still be up if Start partially succeeded.
    }

    if (s_socket != INVALID_SOCKET) {
        // Kicks recvfrom() out of its blocking wait.
        shutdown(s_socket, SD_BOTH);
        closesocket(s_socket);
        s_socket = INVALID_SOCKET;
    }

    if (s_thread.joinable()) {
        s_thread.join();
    }

    if (s_wsaStarted.exchange(false)) {
        WSACleanup();
    }
    LogInfo("[HeadTrackingAim] UDP receiver stopped");
}
