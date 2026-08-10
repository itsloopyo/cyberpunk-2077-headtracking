// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "ModuleGuard.hpp"

#include <windows.h>

void LogError(const char* fmt, ...);
void LogInfo(const char* fmt, ...);

namespace {

struct ImageInfo {
    uintptr_t base = 0;
    size_t    size = 0;
    bool      resolved = false;
};

ImageInfo s_image;

const ImageInfo& Image() {
    if (s_image.resolved) return s_image;
    s_image.resolved = true;

    HMODULE hModule = GetModuleHandleW(L"Cyberpunk2077.exe");
    if (!hModule) return s_image;

    const auto base = reinterpret_cast<uintptr_t>(hModule);
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return s_image;
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return s_image;

    s_image.base = base;
    s_image.size = nt->OptionalHeader.SizeOfImage;
    LogInfo("[ModuleGuard] Cyberpunk2077.exe base=%p size=0x%llX",
            reinterpret_cast<void*>(base),
            static_cast<unsigned long long>(s_image.size));
    return s_image;
}

// True when [rva, rva + size) is covered by a single executable section.
bool InExecutableSection(uintptr_t base, uintptr_t rva, size_t size) {
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    const auto* section = IMAGE_FIRST_SECTION(nt);
    for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++section) {
        const uintptr_t start = section->VirtualAddress;
        const uintptr_t end = start + section->Misc.VirtualSize;
        if (rva < start || rva + size > end) continue;
        return (section->Characteristics & IMAGE_SCN_MEM_EXECUTE) != 0;
    }
    return false;
}

}  // namespace

namespace modguard {

uintptr_t ExeBase() {
    return Image().base;
}

size_t ExeImageSize() {
    return Image().size;
}

uintptr_t ResolveCodeRva(uintptr_t rva, size_t size, const char* who) {
    const ImageInfo& img = Image();
    if (img.base == 0) {
        LogError("[ModuleGuard] %s: Cyberpunk2077.exe is not loaded - lever disabled", who);
        return 0;
    }
    if (rva == 0 || size == 0 || rva + size > img.size) {
        LogError("[ModuleGuard] %s: +0x%llX(+%llu) is outside the running image (size 0x%llX) - "
                 "this build is not the one the offsets were derived from, lever disabled",
                 who,
                 static_cast<unsigned long long>(rva),
                 static_cast<unsigned long long>(size),
                 static_cast<unsigned long long>(img.size));
        return 0;
    }
    if (!InExecutableSection(img.base, rva, size)) {
        LogError("[ModuleGuard] %s: +0x%llX is not in an executable section of the running image - "
                 "lever disabled", who, static_cast<unsigned long long>(rva));
        return 0;
    }
    return img.base + rva;
}

}  // namespace modguard
