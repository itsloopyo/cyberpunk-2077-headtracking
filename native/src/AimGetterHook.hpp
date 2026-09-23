// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <RED4ext/Api/v1/PluginHandle.hpp>
#include <RED4ext/Api/v1/Sdk.hpp>

// Peel the head rotation out of the ANSWERS the shot gets when it asks for the
// camera, instead of mutating the camera itself.
//
// Two levers, both writing into caller-owned temporaries so no camera state is
// touched and nothing round-trips back into the view:
//
//   A +0x802390  GetWorldOrientation(rcx, rdx): copies the camera world
//                orientation quat from [rcx-0x30] into [rdx].
//   C +0x84C968  the weapon-fire routine's `dir = Normalize(target - muzzle)`
//                call site - the shot direction itself, one call per round.
//
// Selected by HeadTrackingState::aim_getter_mode (see SharedState.hpp).
bool AimGetterHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
void AimGetterHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
void AimGetterHook_Tick();
bool AimGetterHook_IsActive();
bool AimGetterHook_CorrectPreviewDirection(float* direction);
