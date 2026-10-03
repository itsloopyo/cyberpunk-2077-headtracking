-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
local defaults = {
    enabled = true, position_enabled = true, enable_on_startup = true,
    yaw_mode = "world", TrueFreeLook = false, FreeLookMarker = false, local_smoothing = 0, remote_smoothing = 0.15,
    clamp_yaw = 120, clamp_pitch = 80, clamp_roll = 45, chase_camera_tracking = true,
    position_limit_x = 0.3, position_limit_y_up = 0.2, position_limit_y_down = 0.2,
    position_limit_z_fwd = 0.4, position_limit_z_back = 0.1,
}
local function copy(source)
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end
local bridge = { saved = copy(defaults), calls = {} }
json = { encode = function(value) return value end, decode = function(value) return value end }
Game = {
    HeadTrackingLoadConfig = function()
        return { values = copy(bridge.saved), defaults = copy(defaults), status = "Canonical", message = "" }
    end,
    HeadTrackingSaveConfig = function(changes)
        if bridge.error then return { error = bridge.error } end
        table.insert(bridge.calls, copy(changes))
        if not bridge.failure then
            for key, value in pairs(changes) do bridge.saved[key] = value end
        end
        return { saved = not bridge.failure, message = bridge.failure or "" }
    end,
}
return bridge
