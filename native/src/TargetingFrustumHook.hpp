// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <RED4ext/Api/v1/PluginHandle.hpp>
#include <RED4ext/Api/v1/Sdk.hpp>

// Keep the scope's lock indicator on the aim rather than on the head.
//
// UI_TargetingInfo.CurrentVisibleTarget comes from a crosshair raycast that asks
// the camera interface for its transform each frame. That camera carries the
// head rotation, so with head tracking the indicator lit for whatever the view
// centre was over while the round went where the mouse aimed. With the sights
// up the hook hands that one call the clean camera instead, picked out by its
// return address. At the hip the target stays the view centre, as stock.
//
// It tells the rendered camera from any other by the targeting record, which the
// update fills from the rendered view: the record is read and never written.
// Other systems read the record as what the player can see, and changing it
// crashed the game a few seconds after a load. Other crosshair queries that go
// through the record (GetObjectClosestToCrosshair and the like) follow the head.
bool TargetingFrustumHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
void TargetingFrustumHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
