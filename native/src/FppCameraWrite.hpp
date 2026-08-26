// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <RED4ext/RED4ext.hpp>

// Re-stamps the FPP camera's orientation slot from native after the script
// tick, so another CET mod writing the same slot later in the frame cannot
// silently win. See FppCameraWrite.cpp for the whole story.

// Registers HeadTrackingSetFppOrientation. Call from the RTTI register
// callback, alongside the other script-channel functions.
void FppCameraWrite_Register(RED4ext::CRTTISystem* rtti);

// Per-frame. Call from NativeRunningHook's OnUpdate.
void FppCameraWrite_Tick();
