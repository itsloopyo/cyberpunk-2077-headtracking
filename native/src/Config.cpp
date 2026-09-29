// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "Config.hpp"
#include "legacy_config/LegacyConfig.hpp"

#include <cameraunlock/config/value_codecs.h>
#include <fstream>
#include <iterator>

namespace htconfig {
using C = cfg::schema::Concept;

cfg::ConfigTable<Config> MakeTable() {
    cfg::ConfigTable<Config> table;
    table.Concept<C::EnableOnStartup>(&Config::enable_on_startup);
    table.Concept<C::RotationEnabled>(&Config::enabled).Writable();
    table.Concept<C::PositionEnabled>(&Config::position_enabled).Writable();
    table.Concept<C::WorldSpaceYaw>(&Config::world_space_yaw).Writable();
    table.Concept<C::TrueFreeLook>(&Config::true_free_look).Writable();
    table.Concept<C::LocalSmoothing>(&Config::local_smoothing).Writable();
    table.Concept<C::RemoteSmoothing>(&Config::remote_smoothing).Writable();
    table.Concept<C::PositionLimitX>(&Config::position_limit_x).Writable();
    table.Concept<C::PositionLimitY>(&Config::position_limit_y_up).Writable();
    table.Concept<C::PositionLimitYDown>(&Config::position_limit_y_down).Writable();
    table.Concept<C::PositionLimitZ>(&Config::position_limit_z_fwd).Writable();
    table.Concept<C::PositionLimitZBack>(&Config::position_limit_z_back).Writable();
    table.Concept<C::ToggleKey>(&Config::toggle_key);
    table.Concept<C::CycleTrackingModeKey>(&Config::mode_key);
    table.Concept<C::YawModeKey>(&Config::yaw_key);
    table.Concept<C::TrueFreeLookKey>(&Config::free_look_key);
    table.Local("Camera", "MaxYawDegrees", &Config::clamp_yaw, cfg::DoubleCodec{},
                "Maximum head rotation in degrees, relative to the aim.").Range(10, 180).Writable();
    table.Local("Camera", "MaxPitchDegrees", &Config::clamp_pitch, cfg::DoubleCodec{}, "").Range(10, 90).Writable();
    table.Local("Camera", "MaxRollDegrees", &Config::clamp_roll, cfg::DoubleCodec{}, "").Range(0, 90).Writable();
    table.Local("Camera", "ChaseCameraTracking", &Config::chase_camera_tracking, cfg::BoolCodec{},
                "Apply head tracking to the third-person vehicle camera.").Writable();
    return table;
}

nlohmann::json ToLua(const Config& c) {
    return {{"enabled", c.enabled}, {"position_enabled", c.position_enabled},
            {"enable_on_startup", c.enable_on_startup},
            {"yaw_mode", c.world_space_yaw ? "world" : "local"}, {"TrueFreeLook", c.true_free_look},
            {"local_smoothing", c.local_smoothing}, {"remote_smoothing", c.remote_smoothing},
            {"position_limit_x", c.position_limit_x}, {"position_limit_y_up", c.position_limit_y_up},
            {"position_limit_y_down", c.position_limit_y_down}, {"position_limit_z_fwd", c.position_limit_z_fwd},
            {"position_limit_z_back", c.position_limit_z_back}, {"clamp_yaw", c.clamp_yaw},
            {"clamp_pitch", c.clamp_pitch}, {"clamp_roll", c.clamp_roll},
            {"chase_camera_tracking", c.chase_camera_tracking}};
}

void ApplyPatch(Config& c, const nlohmann::json& patch) {
    if (!patch.is_object()) throw std::invalid_argument("Config changes must be a JSON object");
    const auto before = ToLua(c);
    for (auto it = patch.begin(); it != patch.end(); ++it) {
        const auto old = before.find(it.key());
        if (old == before.end() || it.key() == "enable_on_startup")
            throw std::invalid_argument("Unknown or read-only setting: " + it.key());
        if ((old->is_boolean() && !it->is_boolean()) || (old->is_number() && !it->is_number()) ||
            (old->is_string() && !it->is_string()))
            throw std::invalid_argument("Incorrect type for setting: " + it.key());
    }
    auto values = before;
    values.update(patch);
    c.enabled = values.at("enabled");
    c.position_enabled = values.at("position_enabled");
    if (!c.enabled && !c.position_enabled) throw std::invalid_argument("Tracking mode needs at least one channel");
    const auto yaw = values.at("yaw_mode").get<std::string>();
    if (yaw != "world" && yaw != "local") throw std::invalid_argument("Invalid yaw mode");
    c.world_space_yaw = yaw == "world";
    c.true_free_look = values.at("TrueFreeLook");
    c.local_smoothing = values.at("local_smoothing");
    c.remote_smoothing = values.at("remote_smoothing");
    c.position_limit_x = values.at("position_limit_x");
    c.position_limit_y_up = values.at("position_limit_y_up");
    c.position_limit_y_down = values.at("position_limit_y_down");
    c.position_limit_z_fwd = values.at("position_limit_z_fwd");
    c.position_limit_z_back = values.at("position_limit_z_back");
    c.clamp_yaw = values.at("clamp_yaw");
    c.clamp_pitch = values.at("clamp_pitch");
    c.clamp_roll = values.at("clamp_roll");
    c.chase_camera_tracking = values.at("chase_camera_tracking");
    // Validate the same codecs and ranges the owner will write before changing the session.
    cfg::RenderCanonical(MakeTable(), c, {"Cyberpunk 2077"});
}

cfg::ImportResult Import(const cfg::LegacyInput& input, Config& out) {
    std::ifstream file(std::filesystem::path(input.path), std::ios::binary);
    if (!file) return cfg::ImportResult::Refused("Cannot read legacy config.json");
    const std::string bytes{std::istreambuf_iterator<char>(file), {}};
    nlohmann::json read;
    try {
        read = legacy::Decode(bytes);
    } catch (const nlohmann::json::exception& e) {
        return cfg::ImportResult::Undecodable(e.what());
    } catch (const std::invalid_argument& e) {
        return cfg::ImportResult::Undecodable(e.what());
    }
    const auto shipped = legacy::Defaults();
    const auto raw = nlohmann::json::parse(bytes);
    if (raw.is_object()) {
        for (const auto& [key, value] : raw.items()) {
            if (!shipped.contains(key) || key == "saved_tracking_mode")
                out.import_messages.push_back("config.json: not carried: " + key + "=" + value.dump());
        }
    }
    if (!read.at("enabled").get<bool>() && !read.at("position_enabled").get<bool>()) {
        const auto mode = read.at("saved_tracking_mode").get<std::string>();
        read["enabled"] = mode != "pos";
        read["position_enabled"] = mode != "rot";
    }
    auto patch = read;
    patch.erase("saved_tracking_mode");
    patch.erase("crosshair_enabled");
    ApplyPatch(out, patch);
    cfg::LegacyFollowsDefaultsIni follows;
    follows.TrackingMode(read.at("enabled") == shipped.at("enabled") &&
                         read.at("position_enabled") == shipped.at("position_enabled"));
    follows.Setting(C::WorldSpaceYaw, read.at("yaw_mode") == shipped.at("yaw_mode"));
    follows.Setting(C::TrueFreeLook, read.at("TrueFreeLook") == shipped.at("TrueFreeLook"));
    follows.Setting(C::LocalSmoothing, read.at("local_smoothing") == shipped.at("local_smoothing"));
    follows.Setting(C::RemoteSmoothing, read.at("remote_smoothing") == shipped.at("remote_smoothing"));
    follows.Setting(C::PositionLimitX, read.at("position_limit_x") == shipped.at("position_limit_x"));
    follows.Setting(C::PositionLimitY, read.at("position_limit_y_up") == shipped.at("position_limit_y_up"));
    follows.Setting(C::PositionLimitYDown, read.at("position_limit_y_down") == shipped.at("position_limit_y_down"));
    follows.Setting(C::PositionLimitZ, read.at("position_limit_z_fwd") == shipped.at("position_limit_z_fwd"));
    follows.Setting(C::PositionLimitZBack, read.at("position_limit_z_back") == shipped.at("position_limit_z_back"));
    for (const auto id : {C::EnableOnStartup, C::ToggleKey, C::CycleTrackingModeKey, C::YawModeKey, C::TrueFreeLookKey})
        follows.NotInLegacy(id);
    std::vector<cfg::DroppedValue> dropped;
    if (!read.at("crosshair_enabled").get<bool>())
        dropped.push_back({cfg::DropRule::Reticle, "", "crosshair_enabled", "false"});
    return cfg::ImportResult::Imported(std::move(dropped), {}, follows.Concepts());
}

cfg::ConfigOwnerOptions<Config> Options(const std::filesystem::path& folder, cfg::DefaultsFile defaults) {
    cfg::ConfigOwnerOptions<Config> options;
    options.path = (folder / "CameraUnlock.ini").wstring();
    options.legacy_path = (folder / "config.json").wstring();
    options.table = MakeTable();
    options.header = {"Cyberpunk 2077"};
    options.defaults = std::move(defaults);
    options.import.run = Import;
    for (const auto& [key, value] : legacy::Defaults().items()) options.import.keys.push_back({"", key});
    return options;
}
}
