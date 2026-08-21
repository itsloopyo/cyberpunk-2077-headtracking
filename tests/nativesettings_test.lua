-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Settings-UI integration self-test. Runnable under stock lua (no CET sandbox):
-- the NativeSettings mod is stubbed and every widget call is recorded.
--
-- The point of this suite is COVERAGE. A settings key with no widget is
-- invisible to anyone configuring the mod in game - including through MCM,
-- which reads the frameworks' registries rather than keeping one of its own -
-- and nothing at runtime complains about it. Adding a setting and forgetting
-- the widget is a silent omission, so it is pinned here instead.
--
-- Also covers the index/string boundary: NativeSettings selectors speak 1-based
-- indices in both directions while the setting stores a string, so a callback
-- that stores the index, or a refresh that pushes the string, both "work"
-- until someone opens the panel.

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("FAIL %s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

local function assert_true(v, label)
    if not v then error("FAIL " .. label .. ": expected truthy, got " .. tostring(v), 2) end
end

-- Minimal json stub: settings.load/save need one, this suite never inspects it.
_G.json = {
    encode = function() return "{}" end,
    decode = function() return nil end,
}

-- Recording NativeSettings stub. Mirrors the argument order of the real
-- framework (justarandomguyintheinternet/CP77_nativeSettings).
local widgets = {}      -- path -> { kind, callback, current, default }
local refreshes = {}    -- path -> last value pushed

local function record(kind, path, callback, current, default)
    widgets[path] = { kind = kind, callback = callback, current = current, default = default }
end

local ns_stub = {
    addTab = function() end,
    addSubcategory = function() end,
    addSwitch = function(path, _, _, current, default, cb) record("switch", path, cb, current, default) end,
    addRangeFloat = function(path, _, _, _, _, _, _, current, default, cb) record("rangeFloat", path, cb, current, default) end,
    addRangeInt = function(path, _, _, _, _, _, current, default, cb) record("rangeInt", path, cb, current, default) end,
    addSelectorString = function(path, _, _, values, current, default, cb)
        record("selector", path, cb, current, default)
        widgets[path].values = values
    end,
    addButton = function(path, _, _, _, _, cb) record("button", path, cb) end,
    refresh = function(path, value) refreshes[path] = value end,
}

function GetMod(name)
    if name == "NativeSettings" then return ns_stub end
    return nil
end

local Settings = require("modules/settings")
local NativeSettingsIntegration = require("modules/nativesettings")

print("== settings UI integration ==")

local settings = Settings.new()
settings.path = "nativesettings_test_config.json"
settings:load()

local integration = NativeSettingsIntegration.new(settings)
assert_true(NativeSettingsIntegration.isAvailable(), "stubbed NativeSettings is detected")
assert_true(integration:init(), "integration initialises against the stub")

-- (1) Coverage. Every setting the user is meant to touch has a widget.
--
-- decouple_diag_clean_cam is deliberately absent: it is a reverse-engineering
-- diagnostic that writes a mouse-only orientation to the camera, and putting it
-- in the settings panel would invite people to break their own view with it. It
-- stays reachable from the CET console.
--
-- saved_tracking_mode is persisted STATE, not a knob: it records which mode the
-- master switch should restore, and is rewritten every time tracking goes off.
local NOT_IN_UI = { decouple_diag_clean_cam = true, saved_tracking_mode = true }

local missing = {}
for key in pairs(settings:getDefaults()) do
    if not NOT_IN_UI[key] and integration.widgetRefs[key] == nil then
        missing[#missing + 1] = key
    end
end
table.sort(missing)
assert_eq(#missing, 0, "every non-diagnostic setting has a widget (missing: " ..
    table.concat(missing, ", ") .. ")")

-- Every registered path must actually correspond to a widget that was created,
-- so a typo in a path string cannot leave a ref pointing at nothing.
for key, path in pairs(integration.widgetRefs) do
    assert_true(widgets[path] ~= nil, "widgetRefs[" .. key .. "] points at a real widget")
end

-- (2) Selector callbacks store the STRING the setting expects, not the index
--     NativeSettings handed them.
local ads_path = integration.widgetRefs["ads_mode"]
assert_eq(widgets[ads_path].kind, "selector", "ads_mode is a selector")
assert_eq(widgets[ads_path].current, 1, "ads_mode selector opens on the stored value (paused)")

widgets[ads_path].callback(3)
assert_eq(settings:get("ads_mode"), "tracked", "selecting index 3 stores 'tracked'")
widgets[ads_path].callback(2)
assert_eq(settings:get("ads_mode"), "marker", "selecting index 2 stores 'marker'")

local yaw_path = integration.widgetRefs["yaw_mode"]
widgets[yaw_path].callback(2)
assert_eq(settings:get("yaw_mode"), "local", "selecting index 2 stores 'local'")

-- (3) The selector order matches the hotkey cycle order, so the dropdown and
--     Home walk the modes the same way.
assert_eq(widgets[ads_path].values[1], "Tracking paused", "slot 1 is the tracking-paused mode")
assert_eq(#widgets[ads_path].values, 3, "three ADS modes offered")

-- (4) A change from outside the panel (the hotkey) refreshes the widget with an
--     INDEX. Pushing the raw string here would silently leave the dropdown on
--     whatever it was showing.
refreshes = {}
integration:onSettingChanged("ads_mode", "tracked")
assert_eq(refreshes[ads_path], 3, "ads_mode refresh pushes the index, not the string")

-- (5) The master Enabled switch is the OR of rotation and position, and is a
--     SEPARATE widget from the rotation switch that stores `enabled`. Folding
--     the two together left no way to reach rotation-only from the panel, and
--     made a position_enabled change refresh the master instead of the
--     position switch.
local master_path = integration.masterWidgetPath
local rot_path = integration.widgetRefs["enabled"]
local pos_path = integration.widgetRefs["position_enabled"]
assert_true(master_path ~= nil, "master switch is registered")
assert_true(master_path ~= rot_path, "master switch is not the rotation switch")
assert_true(widgets[master_path] ~= nil, "master switch points at a real widget")

-- The rotation switch writes `enabled` alone, so rotation-only is reachable.
settings:set("enabled", true)
settings:set("position_enabled", true)
widgets[rot_path].callback(false)
assert_eq(settings:get("enabled"), false, "rotation switch turns rotation off on its own")
assert_eq(settings:get("position_enabled"), true, "rotation switch leaves position alone")

-- The master switch writes both, and restores the mode it took down.
widgets[master_path].callback(false)
assert_eq(settings:get("position_enabled"), false, "master switch clears position too")
widgets[master_path].callback(true)
assert_eq(settings:get("enabled"), false, "master restores position-only, rotation stays off")
assert_eq(settings:get("position_enabled"), true, "master restores position-only, position back on")

-- Turning off the last active axis also switches tracking off. It must record
-- that axis as the mode the master restores.
settings:set("enabled", true)
settings:set("position_enabled", false)
widgets[rot_path].callback(false)
assert_eq(settings:get("saved_tracking_mode"), "rot", "last rotation axis records rotation-only")
widgets[master_path].callback(true)
assert_eq(settings:get("enabled"), true, "master restores rotation-only rotation")
assert_eq(settings:get("position_enabled"), false, "master keeps position off in rotation-only")

settings:set("enabled", false)
settings:set("position_enabled", true)
widgets[pos_path].callback(false)
assert_eq(settings:get("saved_tracking_mode"), "pos", "last position axis records position-only")
widgets[master_path].callback(true)
assert_eq(settings:get("enabled"), false, "master keeps rotation off in position-only")
assert_eq(settings:get("position_enabled"), true, "master restores position-only position")

settings:set("enabled", true)
settings:set("position_enabled", false)
refreshes = {}
integration:onSettingChanged("position_enabled", false)
assert_eq(refreshes[master_path], true, "master follows the pair, not one key")
assert_eq(refreshes[pos_path], false, "position switch refreshes with its own value")

settings:set("enabled", false)
refreshes = {}
integration:onSettingChanged("enabled", false)
assert_eq(refreshes[master_path], false, "master goes off once both keys are off")
assert_eq(refreshes[rot_path], false, "rotation switch refreshes with its own value")

settings:set("position_enabled", true)
refreshes = {}
integration:onSettingChanged("position_enabled", true)
assert_eq(refreshes[master_path], true, "position-only counts as tracking on for the master switch")
assert_eq(refreshes[pos_path], true, "position switch follows back on")

-- (6) A setting with no widget must not throw on the way through - the observer
--     fires for every key, including the diagnostic one.
integration:onSettingChanged("decouple_diag_clean_cam", true)

local exposed = 0
for _ in pairs(integration.widgetRefs) do exposed = exposed + 1 end

integration:shutdown()
-- The callbacks above go through Settings:set(), which autosaves, and a save
-- rotates the previous file to .bak - so both have to come out or the suite
-- leaves litter in the working tree.
os.remove("nativesettings_test_config.json")
os.remove("nativesettings_test_config.json.bak")

print("== Settings UI integration OK: " .. exposed .. " settings exposed ==")
