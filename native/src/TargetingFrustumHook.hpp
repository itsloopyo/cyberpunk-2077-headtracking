// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <RED4ext/Api/v1/PluginHandle.hpp>
#include <RED4ext/Api/v1/Sdk.hpp>

// Keep "what is under the crosshair" on the aim rather than on the head.
//
// The targeting system keeps a per-player record that its update fills from the
// rendered camera every frame: the view orientation and the six planes of the
// view frustum. Every crosshair query measures against that - the scope's lock
// indicator (UI_TargetingInfo.CurrentVisibleTarget), GetObjectClosestToCrosshair
// and the rest - so with head tracking they all followed the head, while the
// round went where the mouse aimed. The same record already carries the clean
// crosshair ray, which is what GetDefaultCrosshairData returns.
//
// The hook lets the update run, then turns the record's view orientation and
// frustum back by the head rotation, so the queries see the aim. The camera
// itself, and so the rendered view, is untouched.
bool TargetingFrustumHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
void TargetingFrustumHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
