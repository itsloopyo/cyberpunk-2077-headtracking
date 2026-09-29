// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "ConfigRuntime.hpp"
#include "Config.hpp"
#include "SharedState.hpp"
#include "AimCompensation.hpp"

#include <RED4ext/RED4ext.hpp>
#include <cameraunlock/input/key_binding_registration.h>
#include <array>
#include <memory>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

namespace {
using namespace htconfig;
std::unique_ptr<cfg::ConfigOwner<Config>> owner;
Config current;
std::unique_ptr<cameraunlock::input::HotkeyPoller> poller;
uint32_t pendingKeys = 0;
std::thread writer;
std::mutex queueMutex;
std::condition_variable queueReady;
std::deque<nlohmann::json> requests;
std::deque<nlohmann::json> completions;
bool stopping = false;
std::string ownerMessage;

void SetBindings() {
    poller = std::make_unique<cameraunlock::input::HotkeyPoller>();
    const std::array<std::string, 4> text{current.toggle_key, current.mode_key, current.yaw_key, current.free_look_key};
    constexpr std::array<uint32_t, 4> flags{1u << 3, 1u << 4, 1u << 5, 1u << 7};
    for (size_t i = 0; i < text.size(); ++i) {
        const auto parsed = cameraunlock::input::ParseKeyBindings(text[i]);
        if (!parsed.ok()) throw std::invalid_argument(parsed.error);
        cameraunlock::input::RegisterKeyBindings(*poller, parsed.bindings, [flag = flags[i]] { pendingKeys |= flag; });
    }
    poller->Poll();
    pendingKeys = 0;
}

void WriteLog(const std::vector<std::string>& lines) {
    for (const auto& line : lines) LogInfo("[Config] %s", line.c_str());
}

void WriteConfigs() {
    for (;;) {
        nlohmann::json patch;
        {
            std::unique_lock lock(queueMutex);
            queueReady.wait(lock, [] { return stopping || !requests.empty(); });
            if (requests.empty()) return;
            patch = std::move(requests.front());
            requests.pop_front();
        }
        nlohmann::json result;
        try {
            ownerMessage.clear();
            const auto saved = owner->Save([&](Config& config) { ApplyPatch(config, patch); });
            WriteLog(saved.log);
            result = {{"saved", saved.status == cfg::ConfigSaveStatus::Saved}, {"message", ownerMessage.empty() ? saved.reason : ownerMessage}};
        } catch (const std::exception& e) {
            LogError("[Config] %s", e.what());
            result = {{"saved", false}, {"message", e.what()}};
        }
        std::lock_guard lock(queueMutex);
        completions.push_back(std::move(result));
    }
}

void Status(RED4ext::IScriptable*, RED4ext::CStackFrame* frame, RED4ext::CString* out, int64_t) {
    ++frame->code;
    std::deque<nlohmann::json> results;
    {
        std::lock_guard lock(queueMutex);
        results.swap(completions);
    }
    *out = nlohmann::json{{"results", results}}.dump().c_str();
}

void Stop(RED4ext::IScriptable*, RED4ext::CStackFrame* frame, void*, int64_t) {
    ++frame->code;
    ConfigRuntime_Shutdown();
}

void Load(RED4ext::IScriptable*, RED4ext::CStackFrame* frame, RED4ext::CString* out, int64_t) {
    ++frame->code;
    try {
        ConfigRuntime_Shutdown();
        wchar_t executable[32768];
        const DWORD length = GetModuleFileNameW(nullptr, executable, 32768);
        if (!length || length == 32768) throw std::runtime_error("Cannot resolve the game executable path");
        const auto folder = std::filesystem::path(executable).parent_path() / "plugins/cyber_engine_tweaks/mods/HeadTracking";
        auto options = Options(folder, cfg::DefaultsFile::PerUser());
        options.status_sink = [](const std::string& message) {
            if (!ownerMessage.empty()) ownerMessage += "\n";
            ownerMessage += message;
        };
        ownerMessage.clear();
        owner = std::make_unique<cfg::ConfigOwner<Config>>(std::move(options));
        const auto loaded = owner->Load();
        current = loaded.config;
        WriteLog(loaded.log);
        WriteLog(current.import_messages);
        SetBindings();
        {
            std::lock_guard lock(queueMutex);
            completions.clear();
            stopping = false;
        }
        writer = std::thread(WriteConfigs);
        *out = nlohmann::json{{"values", ToLua(current)}, {"defaults", ToLua(MakeTable().defaults())},
                             {"status", cfg::ConfigLoadStatusName(loaded.status)}, {"message", ownerMessage.empty() ? loaded.reason : ownerMessage}}.dump().c_str();
    } catch (const std::exception& e) {
        LogError("[Config] %s", e.what());
        *out = nlohmann::json{{"error", e.what()}}.dump().c_str();
    }
}

void Save(RED4ext::IScriptable*, RED4ext::CStackFrame* frame, RED4ext::CString* out, int64_t) {
    RED4ext::CString changes;
    RED4ext::GetParameter(frame, &changes);
    ++frame->code;
    try {
        if (!owner) throw std::logic_error("Config must be loaded before saving");
        const auto patch = nlohmann::json::parse(changes.c_str());
        auto updated = current;
        ApplyPatch(updated, patch);
        {
            std::lock_guard lock(queueMutex);
            if (stopping) throw std::logic_error("Config writer is stopped");
            requests.push_back(patch);
        }
        queueReady.notify_one();
        current = std::move(updated);
        *out = nlohmann::json{{"pending", true}, {"message", ""}}.dump().c_str();
    } catch (const std::exception& e) {
        LogError("[Config] %s", e.what());
        *out = nlohmann::json{{"error", e.what()}}.dump().c_str();
    }
}
}

void ConfigRuntime_Register() {
    auto* rtti = RED4ext::CRTTISystem::Get();
    auto* load = RED4ext::CGlobalFunction::Create("HeadTrackingLoadConfig", "HeadTrackingLoadConfig", &Load);
    load->flags.isNative = true;
    load->SetReturnType("String");
    rtti->RegisterFunction(load);
    auto* save = RED4ext::CGlobalFunction::Create("HeadTrackingSaveConfig", "HeadTrackingSaveConfig", &Save);
    save->flags.isNative = true;
    if (!save->AddParam("String", "changes")) throw std::runtime_error("String RTTI unavailable for config bridge");
    save->SetReturnType("String");
    rtti->RegisterFunction(save);
    auto* status = RED4ext::CGlobalFunction::Create("HeadTrackingConfigStatus", "HeadTrackingConfigStatus", &Status);
    status->flags.isNative = true;
    status->SetReturnType("String");
    rtti->RegisterFunction(status);
    auto* stop = RED4ext::CGlobalFunction::Create("HeadTrackingStopConfig", "HeadTrackingStopConfig", &Stop);
    stop->flags.isNative = true;
    rtti->RegisterFunction(stop);
}

void ConfigRuntime_Shutdown() {
    {
        std::lock_guard lock(queueMutex);
        stopping = true;
    }
    queueReady.notify_one();
    if (writer.joinable()) writer.join();
}

uint32_t ConfigRuntime_PollKeys() {
    if (poller) poller->Poll();
    const uint32_t result = pendingKeys;
    pendingKeys = 0;
    return result;
}
