// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once
#include <cstdint>

bool UdpReceiver_Start(uint16_t port);
void UdpReceiver_Stop();
void UdpReceiver_PublishLatest();

// True when the latest tracking packet came from a remote network device
// rather than from this machine. Drives the LocalSmoothing /
// RemoteSmoothing selection on the Lua side.
bool UdpReceiver_IsRemoteConnection();
