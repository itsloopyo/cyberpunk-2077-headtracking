// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
// Dev builds only: the game takes its keyboard and mouse from a command file
// instead of the real devices, so a test session can run in the background.
#include "../AimCompensation.hpp"

#define CAMERAUNLOCK_ISOLATED_INPUT_IMPLEMENTATION
#include <cameraunlock/dev/isolated_input.h>

#include <string>

namespace {

void InputLog(const char* text) {
    LogInfo("[IsolatedInput] %s", text);
}

} // namespace

// Switched on by the command file being there, beside the plugin, when the
// game starts. Without it a dev build answers to the real keyboard like any
// other.
void StartIsolatedInputIfAsked() {
    HMODULE self = nullptr;
    wchar_t path[MAX_PATH] = {};
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            reinterpret_cast<LPCWSTR>(&StartIsolatedInputIfAsked), &self) ||
        GetModuleFileNameW(self, path, MAX_PATH) == 0) {
        LogError("[IsolatedInput] the plugin's own path could not be read");
        return;
    }
    std::wstring commandFile(path);
    commandFile.resize(commandFile.find_last_of(L"\\/") + 1);
    commandFile += L"CameraUnlockInput.txt";
    if (GetFileAttributesW(commandFile.c_str()) == INVALID_FILE_ATTRIBUTES) return;

    const MH_STATUS ready = MH_Initialize();
    if (ready != MH_OK && ready != MH_ERROR_ALREADY_INITIALIZED) {
        LogError("[IsolatedInput] MinHook could not start (%d)", static_cast<int>(ready));
        return;
    }
    if (!cameraunlock::dev::StartIsolatedInput(commandFile, &InputLog)) {
        LogError("[IsolatedInput] isolated input was asked for and could not be installed");
    }
}
