// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "Config.hpp"
#include "legacy_config/LegacyConfig.hpp"
#include <fstream>
#include <iostream>
#include <iterator>
#include <windows.h>

namespace fs = std::filesystem;
namespace cfg = cameraunlock::config;
using htconfig::Config;

void Require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
std::string Read(const fs::path& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("Cannot read " + path.string());
    return {std::istreambuf_iterator<char>(file), {}};
}
void Write(const fs::path& path, const std::string& text) {
    std::ofstream file(path, std::ios::binary);
    file.exceptions(std::ios::failbit | std::ios::badbit);
    file << text;
}

int main(int argc, char** argv) {
    try {
        const auto table = htconfig::MakeTable();
        const auto fresh = cfg::RenderCanonicalFresh(table, {"Cyberpunk 2077"});
        if (argc == 3 && std::string(argv[1]) == "--render-config") {
            Write(argv[2], fresh);
            return 0;
        }
        Require(Read("CameraUnlock.ini") == fresh, "Committed config differs from fresh render");
        const auto root = fs::temp_directory_path() / ("cyberpunk-config-" + std::to_string(GetCurrentProcessId()) + "-" + std::to_string(GetTickCount64()));
        fs::create_directories(root);
        const auto defaults = cfg::DefaultsFile::At((root / "Defaults.ini").wstring());
        int count = 0;
        auto folder = [&] {
            auto path = root / std::to_string(count++);
            fs::create_directories(path);
            return path;
        };
        if (argc == 2 && std::string(argv[1]) == "--migrate-json") {
            std::string line;
            while (std::getline(std::cin, line)) {
                const auto path = folder();
                const auto legacy = path / "config.json";
                Write(legacy, line);
                const auto timestamp = fs::last_write_time(legacy);
                Require(SetFileAttributesW(legacy.c_str(), FILE_ATTRIBUTE_READONLY), "Cannot make legacy config read-only");
                cfg::ConfigOwner<Config> owner(htconfig::Options(path, defaults));
                const auto loaded = owner.Load();
                Require(loaded.status == cfg::ConfigLoadStatus::Migrated, "Corpus case failed to migrate");
                Require(Read(legacy) == line && fs::last_write_time(legacy) == timestamp, "Corpus migration modified legacy file");
                Require((GetFileAttributesW(legacy.c_str()) & FILE_ATTRIBUTE_READONLY) != 0, "Legacy attribute changed");
                const auto canonical = Read(path / "CameraUnlock.ini");
                cfg::ConfigOwner<Config> second(htconfig::Options(path, defaults));
                const auto reload = second.Load();
                Require(reload.status == cfg::ConfigLoadStatus::Canonical, "Corpus second load imported again");
                Require(htconfig::ToLua(reload.config) == htconfig::ToLua(loaded.config), "Corpus state changed on restart");
                Require(Read(path / "CameraUnlock.ini") == canonical, "Second load rewrote config");
                Require(SetFileAttributesW(legacy.c_str(), FILE_ATTRIBUTE_NORMAL), "Cannot restore scratch file attribute");
                std::cout << htconfig::ToLua(loaded.config).dump() << '\n';
            }
            fs::remove_all(root);
            return 0;
        }
        {
            const auto path = folder();
            cfg::ConfigOwner<Config> owner(htconfig::Options(path, defaults));
            auto loaded = owner.Load();
            Require(loaded.status == cfg::ConfigLoadStatus::Created, "Fresh load did not create config");
            Require(Read(path / "CameraUnlock.ini") == fresh, "First launch differs from render");
        }
        for (const auto& bytes : {std::string("{}"), legacy::Defaults().dump(), Read("config.json")}) {
            const auto path = folder();
            Write(path / "config.json", bytes);
            const auto beforeTime = fs::last_write_time(path / "config.json");
            cfg::ConfigOwner<Config> owner(htconfig::Options(path, defaults));
            const auto loaded = owner.Load();
            Require(loaded.status == cfg::ConfigLoadStatus::Migrated, "Legacy load did not migrate");
            Require(Read(path / "CameraUnlock.ini") == fresh, "Untouched legacy values do not follow defaults");
            Require(Read(path / "config.json") == bytes, "Migration changed legacy bytes");
            Require(fs::last_write_time(path / "config.json") == beforeTime, "Migration changed legacy timestamp");
            cfg::ConfigOwner<Config> second(htconfig::Options(path, defaults));
            Require(second.Load().status == cfg::ConfigLoadStatus::Canonical, "Second launch imported again");
        }
        {
            const auto path = folder();
            auto legacy = legacy::Defaults();
            legacy["enabled"] = false;
            legacy["position_enabled"] = false;
            legacy["saved_tracking_mode"] = "pos";
            legacy["yaw_mode"] = "local";
            legacy["TrueFreeLook"] = true;
            legacy["position_limit_y_down"] = 0.08;
            legacy["remote_smoothing"] = 0.7;
            Write(path / "config.json", legacy.dump());
            cfg::ConfigOwner<Config> owner(htconfig::Options(path, defaults));
            const auto loaded = owner.Load();
            Require(!loaded.config.enabled && loaded.config.position_enabled, "Saved position-only mode lost");
            Require(!loaded.config.world_space_yaw && loaded.config.true_free_look, "Preferences lost");
            Require(!loaded.config.free_look_marker, "True free look from before the marker gained one");
            Require(loaded.config.position_limit_y_down == 0.08 && loaded.config.remote_smoothing == 0.7, "Tuned values lost");
            const auto globalBefore = Read(root / "Defaults.ini");
            auto text = Read(path / "CameraUnlock.ini");
            text += "\r\n; player's comment\r\n[Other]\r\nUnknown=leave me alone\r\n";
            Write(path / "CameraUnlock.ini", text);
            const auto save = owner.Save([](Config& config) { config.world_space_yaw = true; });
            Require(save.status == cfg::ConfigSaveStatus::Saved, "Yaw save failed");
            const auto at = text.find("WorldSpaceYaw=false");
            Require(at != std::string::npos, "Migration did not persist yaw");
            text.replace(at, std::string("WorldSpaceYaw=false").size(), "WorldSpaceYaw=true");
            Require(Read(path / "CameraUnlock.ini") == text, "Save changed unrelated bytes");
            Require(Read(root / "Defaults.ini") == globalBefore, "Save changed global defaults");
            const auto modeSave = owner.Save([](Config& config) { config.enabled = true; config.position_enabled = false; });
            Require(modeSave.status == cfg::ConfigSaveStatus::Saved, "Mode pair save failed");
            const auto reloaded = owner.Reload();
            cfg::ConfigOwner<Config> restart(htconfig::Options(path, defaults));
            const auto state = restart.Load().config;
            Require(state.enabled && !state.position_enabled && state.world_space_yaw, "Saved preferences lost on restart");
        }
        for (const auto* mode : {"paused", "marker", "tracked"}) {
            const auto path = folder();
            auto legacy = legacy::Defaults();
            legacy["ads_mode"] = mode;
            Write(path / "config.json", legacy.dump());
            cfg::ConfigOwner<Config> owner(htconfig::Options(path, defaults));
            const auto loaded = owner.Load();
            Require(loaded.status == cfg::ConfigLoadStatus::Migrated, "A config carrying ads_mode did not load");
            Require(!loaded.config.true_free_look && !loaded.config.free_look_marker, "ads_mode changed the aim mode");
            Require(Read(path / "CameraUnlock.ini") == fresh, "ads_mode reached the canonical file");
        }
        {
            const auto path = folder();
            cfg::ConfigOwner<Config> owner(htconfig::Options(path, defaults));
            const auto created = owner.Load().config;
            Require(!created.true_free_look && !created.free_look_marker, "The aim mode does not default to sights locked");
            auto expected = fresh;
            const auto set = [&expected](const std::string& key, const std::string& from, const std::string& to) {
                const auto at = expected.find(key + "=" + from + "\r\n");
                Require(at != std::string::npos, "Aim mode row missing from the rendered config");
                expected.replace(at, key.size() + 1 + from.size(), key + "=" + to);
            };
            Require(owner.Save([](Config& config) { config.true_free_look = true; config.free_look_marker = true; }).status ==
                        cfg::ConfigSaveStatus::Saved, "Aim mode save failed");
            set("TrueFreeLook", "default", "true");
            set("FreeLookMarker", "default", "true");
            Require(Read(path / "CameraUnlock.ini") == expected, "Aim mode save changed more than its two rows");
            cfg::ConfigOwner<Config> marker(htconfig::Options(path, defaults));
            const auto withMarker = marker.Load().config;
            Require(withMarker.true_free_look && withMarker.free_look_marker, "Free look with a marker lost on restart");
            Require(marker.Save([](Config& config) { config.free_look_marker = false; }).status == cfg::ConfigSaveStatus::Saved,
                    "Aim mode save failed");
            set("FreeLookMarker", "true", "false");
            Require(Read(path / "CameraUnlock.ini") == expected, "Aim mode save changed more than its two rows");
            cfg::ConfigOwner<Config> freeLook(htconfig::Options(path, defaults));
            const auto noMarker = freeLook.Load().config;
            Require(noMarker.true_free_look && !noMarker.free_look_marker, "True free look lost on restart");
        }
        {
            Write(root / "Defaults.ini", "[General]\r\nRotationEnabled=false\r\nWorldSpaceYaw=false\r\n[Position]\r\nPositionEnabled=true\r\nPositionLimitYDown=0.12\r\n");
            const auto path = folder();
            Write(path / "config.json", legacy::Defaults().dump());
            cfg::ConfigOwner<Config> owner(htconfig::Options(path, defaults));
            const auto loaded = owner.Load();
            Require(loaded.status == cfg::ConfigLoadStatus::Migrated, "Custom defaults migration failed");
            Require(!loaded.config.enabled && loaded.config.position_enabled && !loaded.config.world_space_yaw,
                    "Untouched settings overrode Defaults.ini");
            Require(loaded.config.position_limit_y_down == 0.12, "Untouched downward limit overrode defaults");
            Require(Read(path / "CameraUnlock.ini") == fresh, "Custom Defaults.ini was baked into game file");
        }
        for (const auto& bad : {"{bad", "null", "42"}) {
            const auto path = folder();
            Write(path / "config.json", bad);
            cfg::ConfigOwner<Config> owner(htconfig::Options(path, defaults));
            const auto loaded = owner.Load();
            Require(!fs::exists(path / "CameraUnlock.ini"), "Invalid legacy file created canonical config");
            Require(Read(path / "config.json") == bad, "Invalid legacy file changed");
        }
        fs::remove_all(root);
        std::cout << "Config migration, defaults, rendering and save tests passed\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
