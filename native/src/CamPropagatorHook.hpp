// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <RED4ext/Api/v1/PluginHandle.hpp>
#include <RED4ext/Api/v1/Sdk.hpp>

bool CamPropagatorHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
void CamPropagatorHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
bool CamPropagatorHook_IsActive();

// Per-frame tick, called from NativeRunningHook::OnUpdate. It refreshes the
// injection gate from shared memory, flushes the hook's call counters back
// into shared memory and evaluates the heartbeat. The hook itself is on a
// function the game calls hundreds of thousands of times a second across
// several threads, so none of that work can happen per call.
void CamPropagatorHook_Tick(bool gateOpen);
