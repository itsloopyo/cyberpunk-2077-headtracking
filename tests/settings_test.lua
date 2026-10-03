-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
local bridge = require("tests/mock_config_bridge")
local Settings = require("modules/settings")
local settings = Settings.new()
assert(settings:load())
settings:applyLaunchState()
assert(#bridge.calls == 0, "Startup must not pin defaults with a save")
local observed = 0
settings:observe("*", function()
    observed = observed + 1
    assert(settings:get("enabled") or settings:get("position_enabled"), "Mode observers saw a partial pair")
end)
settings:setMode(false, true)
assert(#bridge.calls == 1 and observed == 1)
assert(bridge.calls[1].enabled == false and bridge.calls[1].position_enabled == true)
settings.observers = {}
settings:setTrackingEnabled(false)
assert(not settings:isTrackingEnabled() and #bridge.calls == 1)
settings:setTrackingEnabled(true)
assert(not settings:get("enabled") and settings:get("position_enabled") and #bridge.calls == 1)
settings:set("yaw_mode", "local")
assert(bridge.saved.yaw_mode == "local")
assert(bridge.calls[2].enabled == nil, "Saving yaw must not overwrite the mode")
local AimMode = require("modules/aim_mode")
assert(settings:aimMode() == AimMode.SIGHTS_LOCKED, "The aim mode defaults to sights locked")
local expected_pairs = { { true, true }, { true, false }, { false, false } }
for step, pair in ipairs(expected_pairs) do
    local calls = #bridge.calls
    settings:setAimMode(AimMode.next(settings:aimMode()))
    assert(#bridge.calls == calls + 1, "An aim mode step is one save")
    local saved = bridge.calls[#bridge.calls]
    assert(saved.TrueFreeLook == pair[1] and saved.FreeLookMarker == pair[2],
        "Aim mode step " .. step .. " saved the wrong pair")
    local keys = 0
    for _ in pairs(saved) do keys = keys + 1 end
    assert(keys == 2, "An aim mode step saves nothing but the pair")
end
bridge.saved.TrueFreeLook, bridge.saved.FreeLookMarker = true, nil
local old_free_look = Settings.new()
old_free_look:load()
assert(old_free_look:aimMode() == AimMode.TRUE_FREE_LOOK, "A config from before the marker stays in true free look")
bridge.saved.TrueFreeLook, bridge.saved.FreeLookMarker = false, true
local stray_marker = Settings.new()
stray_marker:load()
assert(stray_marker:aimMode() == AimMode.SIGHTS_LOCKED, "The marker alone is sights locked")
bridge.saved.FreeLookMarker = false
settings:setTrackingEnabled(false)
local restart = Settings.new()
restart:load()
restart:applyLaunchState()
assert(restart:isTrackingEnabled() and not restart:get("enabled"), "Master toggle persisted")
bridge.saved.enable_on_startup = false
restart = Settings.new()
restart:load()
restart:applyLaunchState()
assert(not restart:isTrackingEnabled())
restart:setTrackingEnabled(true)
assert(not restart:get("enabled") and restart:get("position_enabled"))
bridge.failure = "The file is read-only"
restart:set("remote_smoothing", 0.6)
assert(restart:get("remote_smoothing") == 0.6 and bridge.saved.remote_smoothing == 0.15)
assert(restart.message == bridge.failure)
bridge.failure = nil
bridge.error = "Invalid smoothing value"
local ok, err = pcall(function() restart:set("local_smoothing", 4) end)
assert(not ok and err:find(bridge.error, 1, true))
assert(restart:get("local_smoothing") == 0)
bridge.error = nil
assert(not pcall(function() restart:set("crosshair_enabled", false) end))
assert(not pcall(function() restart:set("enable_on_startup", true) end))
Game.HeadTrackingSaveConfig = function() return { pending = true, message = "" } end
local results = {}
Game.HeadTrackingConfigStatus = function() return { results = results } end
local reported
restart.onStatus = function(message) reported = message end
restart:set("local_smoothing", 0.2)
restart:set("remote_smoothing", 0.3)
assert(restart.pendingSaves == 2 and restart:get("local_smoothing") == 0.2)
restart:update()
assert(restart.pendingSaves == 2)
results = { { saved = true, message = "" }, { saved = false, message = "Write denied" } }
restart:update()
assert(restart.pendingSaves == 0 and reported == "Write denied")
print("Settings bridge tests passed")
