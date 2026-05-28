#pragma once
#include <cstdint>

// Starts a background thread that binds a UDP socket on 127.0.0.1:<port>
// (default 4242, the OpenTrack protocol standard) and writes received head-
// pose values into g_sharedState.
//
// OpenTrack's UDP packet is 6 little-endian doubles: x, y, z, yaw, pitch, roll.
// We ignore x/y/z (position tracking isn't wired to the camera yet) and write
// yaw/pitch/roll into the shared memory's raw_* fields, bumping raw_frame.
//
// Replaces the previous Python "opentrack-bridge" process: by running in the
// plugin itself we remove the Python dependency and the RedSocket TCP hop.
//
// Port-retry: if bind() fails (another process holds the port), Start spawns
// a background thread that retries every 5s and brings the receiver online
// the moment the port becomes free. Start returns true in that case so the
// rest of the plugin keeps loading; the user can close a conflicting tracker
// (e.g. another mod, OpenTrack itself) and head tracking will resume on its
// own without restarting the game. Mirrors the C# OpenTrackReceiver behaviour
// shared across the cameraunlock-core mod family.
//
// Both Start and Stop are idempotent.
bool UdpReceiver_Start(uint16_t port);
void UdpReceiver_Stop();
