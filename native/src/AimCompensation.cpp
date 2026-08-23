// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "AimCompensation.hpp"

#include <cameraunlock/logging/file_log.h>

#include <windows.h>
#include <cstdarg>
#include <cstdio>
#include <string>

// One log for the whole mod, written next to Cyberpunk2077.exe as
// HeadTracking.log. A "no head tracking" report has to be answerable from a
// single file the player can find without being told where RED4ext keeps its
// own logs, and the game folder they already browsed to install the mod is the
// one place they will look. cameraunlock::logging rotates the outgoing
// generation to HeadTracking.prev.log and truncates, once per process, so the
// file never grows across sessions while the launch before a crash survives
// the relaunch the player makes before sending it.

namespace {

std::wstring LogPathBesideExe() {
    wchar_t exePath[MAX_PATH] = {0};
    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring path(exePath);
    path.resize(path.find_last_of(L"\\/"));
    return path + L"\\HeadTracking.log";
}

void WriteLog(const char* level, const char* msg) {
    OutputDebugStringA(msg);
    OutputDebugStringA("\n");
    cameraunlock::logging::Line("[%s] %s", level, msg);
}

} // namespace

void Log_Open() {
    cameraunlock::logging::Open(LogPathBesideExe());
}

void Log_Close() {
    cameraunlock::logging::Close();
}

void LogInfo(const char* format, ...) {
    char buffer[512];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    WriteLog("info", buffer);
}

void LogWarning(const char* format, ...) {
    char buffer[512];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    WriteLog("warning", buffer);
}

void LogError(const char* format, ...) {
    char buffer[512];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    WriteLog("error", buffer);
}
