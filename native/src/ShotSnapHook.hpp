// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <RED4ext/RED4ext.hpp>

bool ShotSnapHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
void ShotSnapHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
bool ShotSnapHook_IsActive();
