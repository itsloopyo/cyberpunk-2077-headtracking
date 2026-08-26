// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <RED4ext/RED4ext.hpp>

// Re-stamps the FPP camera's orientation slot from native after the script
// tick, undoing anything that wrote it between our Lua write and this tick.
// It does NOT beat a writer that runs after this tick, which is why it is not
// what fixed the Shift conflict. See FppCameraWrite.cpp before relying on it.

// Registers HeadTrackingSetFppOrientation. Call from the RTTI register
// callback, alongside the other script-channel functions.
void FppCameraWrite_Register(RED4ext::CRTTISystem* rtti);

// Per-frame. Call from NativeRunningHook's OnUpdate.
void FppCameraWrite_Tick();
