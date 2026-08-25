// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <RED4ext/Api/v1/PluginHandle.hpp>
#include <RED4ext/Api/v1/Sdk.hpp>

// Head tracking for the vehicle chase camera.
//
// Everywhere else in this mod the head rotation reaches the screen through the
// player's FPP camera component: Lua composes it into cam.localOrientation and
// the engine renders from there. In a vehicle in third person that component
// renders nothing, and the chase camera's own localOrientation is dormant -
// writes to it are kept and read by nobody. So there is no script route at all
// and this hook is the whole feature.
//
// It detours the camera publish, whose `this` carries the camera's own pose,
// and composes the head rotation into it there. That is upstream of every
// consumer at once: the render params the scene draws from, and the HUD's
// world-to-screen, which reads the camera object and no render copy - so
// world-anchored markers track with the view instead of sitting still on
// screen while the world moves under them.
//
// It is upstream of weapon aim too, which is the same position first person is
// already in, and the same machinery handles it: AimProviderHook and
// AimGetterHook peel the head rotation back out of the shot direction so the
// mouse keeps the aim.

bool ChaseCameraHook_Start(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);
void ChaseCameraHook_Stop(const RED4ext::v1::Sdk* sdk, RED4ext::v1::PluginHandle handle);

// Detours the publish if it is not detoured yet. Called once the chase camera
// is actually active, so a session that never drives in third person never gets
// the detour.
void ChaseCameraHook_EnsureInstalled();

// The chase camera's world orientation as the frame renders it, head rotation
// included. False when nothing has published one yet.
//
// The aim peels need it. They decide whether a quaternion is the player's own
// aim by dotting it against the camera's world orientation, and the camera they
// reach for otherwise is the FIRST-PERSON one, which in this camera stays clean
// and mouse-only. An aim quat carrying the head rotation then drifts away from
// it as the head moves, the dot falls under the gate, and the peel switches
// itself off for exactly the frames it is needed.
bool ChaseCameraHook_WorldOrientation(float* out);
