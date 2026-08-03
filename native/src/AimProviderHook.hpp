#pragma once

#include <RED4ext/Api/v1/PluginHandle.hpp>
#include <RED4ext/Api/v1/Sdk.hpp>
#include <cstdint>

// VMT instrument + head-peel override on entIOrientationProvider.
//
// The player's shot direction comes from an orientation provider attached to
// the projectile launch event (gameprojectileLaunchParams.logicalOrientationProvider).
// For the player that provider returns the camera orientation, which is where
// the head rotation leaks into the bullet. Overriding the provider's OUT quat
// peels the head rotation off the aim without touching a single byte of camera
// state, so there is no camera round-trip to fight and every round of an
// automatic burst is decoupled (the provider is asked once per pellet).
//
// Install needs RTTI, so it is driven from NativeRunningHook's OnUpdate via
// AimProviderHook_Tick() rather than from plugin load.
bool AimProviderHook_Tick();
void AimProviderHook_Stop();
bool AimProviderHook_IsActive();
