// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <cstddef>
#include <cstdint>

// Per-build pinning for the hooks that cannot resolve their target at runtime.
//
// Two classes of constant live in this plugin and they carry very different
// risk, so only one of them is gated here.
//
//   Code RVAs (this file). A detour is a write of a jump into the middle of a
//   function. Point it at an address that belongs to a different function on a
//   patched build and the game executes our thunk with the wrong calling
//   convention and arguments, which crashes within seconds of loading a save.
//   These are keyed on the exact shipped EXE via a PE fingerprint and stay
//   dormant on any build we have not derived them against.
//
//   Struct field offsets and vtable slot indices (NOT this file - they live
//   next to the hook that uses them). Those are compiled from the game's source
//   layout, so they are stable across stores for the same game version, where
//   RVAs are not: the GOG, Steam and Epic EXEs of one patch are separate builds
//   with different code addresses but identical struct layouts. They are also
//   read through a pointer we obtained from RTTI, are range- and sanity-checked
//   at the point of use, and have a runtime scan fallback. Gating them on an
//   exact EXE match would leave every store we have not fingerprinted with a
//   dormant mod to guard against a constant that almost certainly still holds.
//
// The registry is append-only. When a patch moves the RVAs, ADD a profile; do
// not edit an existing one, or every user still on the older build loses the
// mod with no way back. See "Maintain compatibility across new patches" in
// AGENTS.md.

namespace builds {

// The PE header fields that together identify one shipped EXE. Three
// independent fields means a repacked or tampered binary fails the match
// instead of silently routing to offsets that no longer describe it.
struct PeFingerprint {
    uint32_t TimeDateStamp;
    uint32_t SizeOfImage;
    uint32_t CheckSum;
};

// Every code address this plugin pins to a specific build. Zero means "not
// derived for this build", and the lever that reads it stays disabled - which
// is what lets a placeholder profile land the moment a patch is spotted,
// before the rederive is done, without risking activation.
struct OffsetTable {
    uintptr_t GetWorldOrientation;  // AimGetter lever A detour target
    uintptr_t FireNormaliseCall;    // AimGetter lever C: the `call Normalize` site
    uintptr_t NormaliseFn;          // AimGetter lever C: the Normalize callee
    uintptr_t RicochetEffectExecute;
    uintptr_t PhysicalRayExecute;
    uintptr_t PhysicalRayNormaliseCall;
    // The two sites inside the smart weapon's camera-transform builder that ask
    // lever A for the camera orientation. They are return addresses, not
    // function entries: the peel is selected by WHO asked, so only the smart
    // weapon's targeting sees a head-free camera. Identified by the caller
    // histogram - they appear only while a smart weapon is equipped.
    uintptr_t SmartGunCameraCallA;
    uintptr_t SmartGunCameraCallB;
    // The camera publish, +0x127404. Its `this` carries the camera's OWN pose at
    // this+0x4C0 - fixed-point world position at +0x00, orientation quaternion
    // at +0x10 - which the pose builder at +0x4E9398 reads and every copy the
    // engine hands out is made from. ChaseCameraHook composes the head rotation
    // in there, which is the only route to the vehicle chase camera: that
    // camera renders from its own component and ignores every write to the
    // player's FPP camera.
    uintptr_t CameraPublishFn;
    // The targeting system's per-player update, +0x4B9D84(record, camera). It
    // copies the rendered camera - head rotation included - into the record's
    // view orientation and frustum, which every "what is under the crosshair"
    // query then measures against: the scope's lock indicator, the UI's
    // visible target, GetObjectClosestToCrosshair. TargetingFrustumHook turns
    // that view back onto the clean aim once the update has run.
    uintptr_t TargetingRecordUpdate;
    // The engine's direction -> (roll, pitch, yaw) conversion, +0x396F30(dir,
    // out), which the update uses to derive the crosshair angles every
    // crosshair query is measured from.
    uintptr_t DirectionToAngles;
    // The UI targeting job's range and obstruction query, +0x3FB4C8(this, ray,
    // angles, ...), and the return address of the one call we correct: the
    // job that fills UI_TargetingInfo builds that ray from the rendered camera.
    uintptr_t UiTargetRayQuery;
    uintptr_t UiTargetRayQueryReturn;
    // The camera interface's transform getter, +0x4E8D68(this, out, owner):
    // position, then orientation at out+0x10. The crosshair raycast that picks
    // UI_TargetingInfo.CurrentVisibleTarget asks it for the camera each frame,
    // from the call whose return address is below.
    uintptr_t CameraTransformFn;
    uintptr_t CrosshairRaycastCameraReturn;
};

struct BuildProfile {
    const char*   Name;
    PeFingerprint Fingerprint;
    OffsetTable   Offsets;
};

}  // namespace builds
