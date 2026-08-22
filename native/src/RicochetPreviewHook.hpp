// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <RED4ext/Api/v1/PluginHandle.hpp>
#include <RED4ext/Api/v1/Sdk.hpp>

bool RicochetPreviewHook_Start(const RED4ext::v1::Sdk* sdk,
                               RED4ext::v1::PluginHandle handle);
void RicochetPreviewHook_Stop(const RED4ext::v1::Sdk* sdk,
                              RED4ext::v1::PluginHandle handle);
