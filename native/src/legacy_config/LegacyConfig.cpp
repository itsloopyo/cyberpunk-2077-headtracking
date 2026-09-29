// SPDX-License-Identifier: MIT
// Copyright (c) 2026 itsloopyo
#include "LegacyConfig.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace legacy {
nlohmann::json Defaults() {
    return {{"enabled", true}, {"local_smoothing", 0.0}, {"remote_smoothing", 0.15},
            {"clamp_yaw", 120.0}, {"clamp_pitch", 80.0}, {"clamp_roll", 45.0},
            {"crosshair_enabled", true}, {"position_enabled", true},
            {"position_limit_x", 0.30}, {"position_limit_y_up", 0.20},
            {"position_limit_y_down", 0.05}, {"position_limit_z_fwd", 0.40},
            {"position_limit_z_back", 0.10}, {"yaw_mode", "world"},
            {"saved_tracking_mode", "both"}, {"chase_camera_tracking", true},
            {"TrueFreeLook", false}};
}

nlohmann::json Decode(const std::string& bytes) {
    const auto input = nlohmann::json::parse(bytes);
    if (!input.is_object() && !input.is_array())
        throw std::invalid_argument("Legacy config.json must contain an object or array");
    auto out = Defaults();
    if (input.is_object()) {
        for (auto it = out.begin(); it != out.end(); ++it) {
            const auto found = input.find(it.key());
            if (found == input.end()) continue;
            if ((it->is_boolean() && found->is_boolean()) ||
                (it->is_number() && found->is_number()) ||
                (it->is_string() && found->is_string())) *it = *found;
        }
    }
    for (const auto* key : {"local_smoothing", "remote_smoothing"})
        out[key] = std::clamp(out[key].get<double>(), 0.0, 1.0);
    out["clamp_yaw"] = std::clamp(out["clamp_yaw"].get<double>(), 10.0, 180.0);
    out["clamp_pitch"] = std::clamp(out["clamp_pitch"].get<double>(), 10.0, 90.0);
    out["clamp_roll"] = std::clamp(out["clamp_roll"].get<double>(), 0.0, 90.0);
    for (const auto* key : {"position_limit_x", "position_limit_y_up", "position_limit_y_down",
                            "position_limit_z_fwd", "position_limit_z_back"})
        out[key] = std::clamp(out[key].get<double>(), 0.0, 0.5);
    if (out["yaw_mode"] != "world" && out["yaw_mode"] != "local") out["yaw_mode"] = "world";
    if (out["saved_tracking_mode"] != "both" && out["saved_tracking_mode"] != "rot" &&
        out["saved_tracking_mode"] != "pos") out["saved_tracking_mode"] = "both";
    return out;
}
}
