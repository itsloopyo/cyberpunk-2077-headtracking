// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <RED4ext/Api/v1/PluginHandle.hpp>
#include <RED4ext/Api/v1/Sdk.hpp>

// =============================================================================
// Hitscan aim-compensation hook
// =============================================================================
//
// WHY THIS EXISTS
// ---------------
// Projectile weapons (SMGs with tracers, shotguns, thrown grenades) flow
// through the function hooked by AimCompensation.cpp at +0x28D4B8 - there
// we can intercept arg1+0xF0 / arg1+0x100 / arg1+0x110 and rotate by the
// inverse head quat, and the bullet lands where the mouse points.
//
// Hitscan weapons (pistols mainly) BYPASS that function entirely. They
// dispatch directly through a native raycast call chain that reads the
// camera's orientation right at the moment of TraceRay. modules/aim.lua
// compensated for this by SNAP-CLEAN'ing the cam.localOrientation to body-
// forward for ONE frame, letting hitscan read the clean pose, then
// restoring head rotation on the next frame. That works (bullets land
// true) but leaves a one-frame visual "camera jump to reticle and back"
// that the user can see every single shot.
//
// This hook kills SNAP-CLEAN by intercepting the generic trace dispatcher at
// +0x1303EC during the one-shot window Lua publishes from PlayerPuppet:OnAction.
// It rotates the trace input by the inverse head yaw/pitch before the original
// dispatcher builds the physics query.
//
// HOOK TARGET: function +0x1303EC, gated by pending_native_restore.
//
// Kill-switch: if the function can't be located OR the hook attach fails,
// the hook stays dormant and Lua's SNAP-CLEAN fallback continues to do
// its thing. No flash fix, but no regression either.
// =============================================================================

bool HitscanHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
void HitscanHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
bool HitscanHook_IsActive();
