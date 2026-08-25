// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once
#include <cstdint>

// The CET Lua mod's only channel to this plugin.
//
// Two global RTTI functions, registered into the game's script system, which
// CET Lua calls directly as Game.HeadTrackingPollPose / Game.HeadTrackingPushState:
//
//   Bool HeadTrackingPollPose(out Float yaw, out Float pitch, out Float roll,
//                             out Float x, out Float y, out Float z,
//                             out Uint32 flags)
//   Bool HeadTrackingPushState(Float yaw, Float pitch, Float roll,
//                              Bool enabled, Bool isAds,
//                              Float qi, Float qj, Float qk, Float qr,
//                              Bool propagatorInject,
//                              Float positionX, Float positionY, Float positionZ,
//                              Float aimDistance, Bool chaseCamera)
//   Bool HeadTrackingPushRicochetState(Bool valid,
//                                      Float hitX, Float hitY, Float hitZ,
//                                      Float normalX, Float normalY, Float normalZ,
//                                      Float forwardX, Float forwardY, Float forwardZ)
//
// Registration is queued at plugin load and runs when the game builds its RTTI
// registry. It does not depend on the build fingerprint, so on an unrecognised
// game build - where every RVA-pinned hook stays dormant - Lua still gets its
// pose and still drives the camera through its own fallback path.
void ScriptChannel_Register();

// Wall-clock milliseconds since the script side last called PushState, or 0 if
// it never has. Drives the "nothing is listening" diagnostic.
uint64_t ScriptChannel_MsSinceLastPush();
bool ScriptChannel_HasEverPushed();

// The last state the CET mod pushed. A healthy plugin log looks identical
// whether the Lua gameplay gate is open or shut - the push keeps arriving
// either way - so without these the native log cannot tell "the mod is
// suppressing tracking" (a menu / cinematic / ADS verdict, whose reason is in
// CET's scripting.log) from "the mod thinks it is tracking and the camera
// write is not landing". Those are different investigations and the log people
// send us has to pick one.
bool ScriptChannel_LastPushEnabled();
bool ScriptChannel_LastPushIsAds();

// Rotation magnitude of the last pushed head quaternion, in degrees.
float ScriptChannel_LastPushHeadDegrees();

// True while the player is looking through the vehicle chase camera and the
// gameplay gate is open.
//
// ChaseCameraHook injects ONLY while it is true: the chase camera renders from
// its own component, so the Lua camera write - the whole FPP path - reaches
// nothing there. The aim peels read it to pick which camera to compare an aim
// quaternion against, since the first-person camera stays clean in the chase
// camera and every comparison against it would fail by the head angle.
bool ScriptChannel_ChaseCameraActive();
