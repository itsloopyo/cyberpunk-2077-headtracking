// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <cstddef>
#include <cstdint>

// Every native hook in this plugin derives its target from a hardcoded RVA that
// was read out of one specific Cyberpunk2077.exe build. A game patch (or a
// different store SKU) changes the image, and an RVA past the end of the new
// image faults the moment it is dereferenced - at plugin load, before the user
// has done anything. These helpers turn that into a refusal plus a log line.
//
// This is a bounds check, not a build check: an RVA that still lands inside the
// image but now points at a different function is not detectable here. The
// build-profile fingerprint registry described in AGENTS.md ("Per-Build Camera
// Addresses") is what closes that gap; until a profile is stamped from a real
// EXE this keeps the out-of-image case from crashing the game.
namespace modguard {

// Base address of the running Cyberpunk2077.exe, or 0 when it is not loaded.
uintptr_t ExeBase();

// SizeOfImage from the running image's PE headers, or 0 when unavailable.
size_t ExeImageSize();

// Absolute address for `rva` when [rva, rva + size) lies wholly inside an
// executable section of the running image. Returns 0 otherwise, after logging
// the refusal against `who` (the lever name, for the user's bug report).
uintptr_t ResolveCodeRva(uintptr_t rva, size_t size, const char* who);

}  // namespace modguard
