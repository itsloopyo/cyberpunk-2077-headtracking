// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "AimCompensation.hpp"
#include <windows.h>
#include <cstdarg>
#include <cstdio>
#include <mutex>
#include <string>

// red4ext doesn't expose its logger to plugins by default and OutputDebugString
// only shows in a debugger. Mirror everything to a plain file at
// <game>\red4ext\logs\HeadTrackingAim.log so users can read it after the fact.

namespace {
std::mutex g_logMutex;
FILE* g_logFile = nullptr;
bool g_logFileTried = false;

FILE* OpenLogFile() {
    if (g_logFileTried) return g_logFile;
    g_logFileTried = true;

    wchar_t exePath[MAX_PATH] = {0};
    HMODULE hExe = GetModuleHandleW(L"Cyberpunk2077.exe");
    if (!hExe || GetModuleFileNameW(hExe, exePath, MAX_PATH) == 0) {
        return nullptr;
    }

    // Strip "Cyberpunk2077.exe", "x64\", "bin\" -> game root.
    std::wstring path(exePath);
    for (int i = 0; i < 3; ++i) {
        size_t slash = path.find_last_of(L"\\/");
        if (slash == std::wstring::npos) return nullptr;
        path.resize(slash);
    }
    path += L"\\red4ext\\logs\\HeadTrackingAim.log";

    g_logFile = _wfopen(path.c_str(), L"a");
    if (g_logFile) {
        SYSTEMTIME st;
        GetLocalTime(&st);
        fprintf(g_logFile,
                "\n=== HeadTrackingAim log opened %04d-%02d-%02d %02d:%02d:%02d ===\n",
                st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
        fflush(g_logFile);
    }
    return g_logFile;
}

void WriteLog(const char* level, const char* msg) {
    OutputDebugStringA(msg);
    OutputDebugStringA("\n");

    std::lock_guard<std::mutex> lock(g_logMutex);
    FILE* f = OpenLogFile();
    if (!f) return;
    SYSTEMTIME st;
    GetLocalTime(&st);
    fprintf(f, "[%02d:%02d:%02d.%03d] [%s] %s\n",
            st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, level, msg);
    fflush(f);
}
} // namespace

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
