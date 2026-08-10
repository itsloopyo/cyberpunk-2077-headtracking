// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once
#include <cstdint>

// Tiny TCP server that the CET Lua mod connects to via RedSocket.
//
// Protocol matches the old Python bridge so udp.lua's existing client code
// works unchanged:
//   client -> "G"               (single byte; no terminator required)
//   server -> "<seq>,<yaw:.4f>,<pitch:.4f>,<roll:.4f>\r\n"
//
// Pose values come from g_sharedState.raw_* (populated by the UDP receiver).
//
// One client at a time is sufficient - this is local IPC, not a fan-out.
//
// Both Start and Stop are idempotent.
bool TcpServer_Start(uint16_t port);
void TcpServer_Stop();
