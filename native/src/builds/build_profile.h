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
    uintptr_t Propagator;           // CamPropagatorHook detour target
    uintptr_t GetWorldOrientation;  // AimGetter lever A detour target
    uintptr_t GetWorldTransform;    // AimGetter lever B detour target
    uintptr_t FireNormaliseCall;    // AimGetter lever C: the `call Normalize` site
    uintptr_t NormaliseFn;          // AimGetter lever C: the Normalize callee
    uintptr_t RicochetEffectExecute;
    uintptr_t PhysicalRayExecute;
    uintptr_t PhysicalRayNormaliseCall;
};

struct BuildProfile {
    const char*   Name;
    PeFingerprint Fingerprint;
    OffsetTable   Offsets;
};

}  // namespace builds
