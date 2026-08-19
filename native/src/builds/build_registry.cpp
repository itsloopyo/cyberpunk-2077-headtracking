// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "build_registry.hpp"

#include <windows.h>

#include "../ModuleGuard.hpp"

void LogInfo(const char* fmt, ...);
void LogWarning(const char* fmt, ...);

namespace builds {

extern const BuildProfile kGogProfile_20250827;

namespace {

// Newest first. The top entry is the diagnostic primary: when nothing matches,
// its build date decides whether we tell the user their game is newer than this
// mod knows about or older than it supports.
const BuildProfile* const kKnownProfiles[] = {
    &kGogProfile_20250827,
};

constexpr size_t kKnownProfileCount = sizeof(kKnownProfiles) / sizeof(kKnownProfiles[0]);

const BuildProfile kNoProfile = { "none", { 0, 0, 0 }, { 0, 0, 0, 0, 0 } };

bool         s_selected = false;
SelectResult s_result   = SelectResult::NoImage;
const BuildProfile* s_active = nullptr;

bool ReadRunningFingerprint(PeFingerprint& out) {
    const uintptr_t base = modguard::ExeBase();
    if (base == 0) return false;

    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return false;

    out.TimeDateStamp = nt->FileHeader.TimeDateStamp;
    out.SizeOfImage   = nt->OptionalHeader.SizeOfImage;
    out.CheckSum      = nt->OptionalHeader.CheckSum;
    return true;
}

bool SameFingerprint(const PeFingerprint& a, const PeFingerprint& b) {
    return a.TimeDateStamp == b.TimeDateStamp &&
           a.SizeOfImage   == b.SizeOfImage &&
           a.CheckSum      == b.CheckSum;
}

// Everything the mismatch needs to be actionable in a bug report without a
// follow-up round trip: what is running, what we compared against, and which
// direction the difference points.
void LogMismatch(const PeFingerprint& running, SelectResult result) {
    LogWarning("[BuildRegistry] running Cyberpunk2077.exe: TimeDateStamp=0x%08X SizeOfImage=0x%08X CheckSum=0x%08X",
               running.TimeDateStamp, running.SizeOfImage, running.CheckSum);
    for (size_t i = 0; i < kKnownProfileCount; ++i) {
        const BuildProfile* p = kKnownProfiles[i];
        LogWarning("[BuildRegistry]   known profile %s: TimeDateStamp=0x%08X SizeOfImage=0x%08X CheckSum=0x%08X",
                   p->Name, p->Fingerprint.TimeDateStamp, p->Fingerprint.SizeOfImage, p->Fingerprint.CheckSum);
    }
    switch (result) {
    case SelectResult::NewerThanKnown:
        LogWarning("[BuildRegistry] This game build is NEWER than any build this mod was derived against.");
        LogWarning("[BuildRegistry] The game has been patched. Check the mod's releases page for an update.");
        break;
    case SelectResult::OlderThanKnown:
        LogWarning("[BuildRegistry] This game build is OLDER than any build this mod was derived against.");
        LogWarning("[BuildRegistry] Let the store finish updating the game, or use a mod release matching this build.");
        break;
    case SelectResult::Tampered:
        LogWarning("[BuildRegistry] This EXE has a known build date but a different size or checksum -");
        LogWarning("[BuildRegistry] a repacked or modified binary. This mod will not engage on it.");
        break;
    default:
        break;
    }
    LogWarning("[BuildRegistry] The RVA-pinned hooks stay DORMANT. Head tracking, the view camera and");
    LogWarning("[BuildRegistry] projectile aim decoupling do not depend on them and still run.");
}

}  // namespace

SelectResult SelectProfile() {
    if (s_selected) return s_result;
    s_selected = true;

    PeFingerprint running{};
    if (!ReadRunningFingerprint(running)) {
        LogWarning("[BuildRegistry] could not read Cyberpunk2077.exe PE headers - RVA-pinned hooks disabled");
        s_result = SelectResult::NoImage;
        return s_result;
    }

    for (size_t i = 0; i < kKnownProfileCount; ++i) {
        if (SameFingerprint(running, kKnownProfiles[i]->Fingerprint)) {
            s_active = kKnownProfiles[i];
            s_result = SelectResult::Matched;
            LogInfo("[BuildRegistry] matched build profile %s", s_active->Name);
            return s_result;
        }
    }

    // A shared TimeDateStamp with a differing size or checksum is a repack, not
    // a patch: CDPR relinking the EXE moves the timestamp too.
    bool sameStampDifferentImage = false;
    for (size_t i = 0; i < kKnownProfileCount; ++i) {
        if (running.TimeDateStamp == kKnownProfiles[i]->Fingerprint.TimeDateStamp) {
            sameStampDifferentImage = true;
            break;
        }
    }

    if (sameStampDifferentImage) {
        s_result = SelectResult::Tampered;
    } else if (running.TimeDateStamp > DiagnosticPrimary().Fingerprint.TimeDateStamp) {
        s_result = SelectResult::NewerThanKnown;
    } else {
        s_result = SelectResult::OlderThanKnown;
    }

    LogMismatch(running, s_result);
    return s_result;
}

bool HasActiveProfile() {
    return s_active != nullptr;
}

const BuildProfile& ActiveProfile() {
    return s_active ? *s_active : kNoProfile;
}

const BuildProfile& DiagnosticPrimary() {
    return *kKnownProfiles[0];
}

}  // namespace builds
