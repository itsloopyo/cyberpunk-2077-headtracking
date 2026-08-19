// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include "build_profile.h"

namespace builds {

enum class SelectResult {
    Matched,          // running EXE matches a known profile
    NoImage,          // Cyberpunk2077.exe headers unreadable
    NewerThanKnown,   // built after every profile we carry - game patched, mod needs updating
    OlderThanKnown,   // built before every profile we carry - user is on an older patch
    Tampered,         // same build date as a known profile, different size or checksum
};

// Fingerprints the running EXE and selects a profile. Call once at plugin load,
// before any RVA-pinned hook is installed. Repeat calls return the first result.
SelectResult SelectProfile();

// True once SelectProfile() has returned Matched. Every RVA-pinned hook must
// check this before touching game memory.
bool HasActiveProfile();

// The matched profile. Only valid when HasActiveProfile(); calling it otherwise
// returns a profile whose offsets are all zero, so a caller that forgets the
// check disables its lever rather than detouring address zero.
const BuildProfile& ActiveProfile();

// Newest profile we know about, used to label which direction an unrecognised
// build sits in. Never null.
const BuildProfile& DiagnosticPrimary();

}  // namespace builds
