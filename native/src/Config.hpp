// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#pragma once

#include <cameraunlock/config/config_owner.h>
#include <nlohmann/json.hpp>
#include <filesystem>

namespace htconfig {
namespace cfg = cameraunlock::config;
struct Config {
    bool enable_on_startup = true;
    bool enabled = true;
    bool position_enabled = true;
    bool world_space_yaw = true;
    bool true_free_look = false;
    double local_smoothing = 0.0;
    double remote_smoothing = 0.15;
    double position_limit_x = 0.30;
    double position_limit_y_up = 0.20;
    double position_limit_y_down = 0.20;
    double position_limit_z_fwd = 0.40;
    double position_limit_z_back = 0.10;
    double clamp_yaw = 120.0;
    double clamp_pitch = 80.0;
    double clamp_roll = 45.0;
    bool chase_camera_tracking = true;
    std::string toggle_key = cfg::schema::ConceptTraits<cfg::schema::Concept::ToggleKey>::kCanonicalDefault;
    std::string mode_key = cfg::schema::ConceptTraits<cfg::schema::Concept::CycleTrackingModeKey>::kCanonicalDefault;
    std::string yaw_key = cfg::schema::ConceptTraits<cfg::schema::Concept::YawModeKey>::kCanonicalDefault;
    std::string free_look_key = cfg::schema::ConceptTraits<cfg::schema::Concept::TrueFreeLookKey>::kCanonicalDefault;
    std::vector<std::string> import_messages;
};
cfg::ConfigTable<Config> MakeTable();
cfg::ImportResult Import(const cfg::LegacyInput& input, Config& out);
cfg::ConfigOwnerOptions<Config> Options(const std::filesystem::path& folder, cfg::DefaultsFile defaults);
nlohmann::json ToLua(const Config& config);
void ApplyPatch(Config& config, const nlohmann::json& patch);
}
