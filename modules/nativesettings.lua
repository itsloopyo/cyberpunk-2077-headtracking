-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Native Settings UI Integration Module
-- Optional integration with the NativeSettings mod for in-game configuration
-- https://www.nexusmods.com/cyberpunk2077/mods/3518
-- Production-ready implementation with state sync, reset functionality, and observer integration

local NativeSettingsIntegration = {}
NativeSettingsIntegration.__index = NativeSettingsIntegration

-- String-valued settings shown as dropdowns. NativeSettings selectors speak
-- 1-based INDICES in both directions - the callback receives one and setOption()
-- expects one - while the setting itself stores the string, so every crossing
-- goes through these two tables. `values` is the stored order and must stay in
-- step with the hotkey cycle in init.lua, so the dropdown and the key walk the
-- modes the same way.
local ENUM_SETTINGS = {
    ads_mode = {
        values = { "paused", "marker", "tracked" },
        labels = {
            "Tracking paused",
            "Tracking on, aim marker shown",
            "Tracking on, no aim marker",
        },
    },
    yaw_mode = {
        values = { "world", "local" },
        labels = { "World (horizon-locked)", "Camera-relative" },
    },
}

--- Index of a stored enum string, for a selector widget.
--- Falls back to the first entry: a value that is not in the list cannot be
--- shown, and the settings layer has already rejected anything invalid, so this
--- only fires if the two lists drift apart.
--- @param key string
--- @param value any
--- @return number
local function enumIndex(key, value)
    local spec = ENUM_SETTINGS[key]
    if not spec then return 1 end
    for i, v in ipairs(spec.values) do
        if v == value then return i end
    end
    return 1
end

--- Create a new Native Settings integration instance
--- @param settings_ref table Reference to the Settings module instance
--- @return table NativeSettingsIntegration instance
function NativeSettingsIntegration.new(settings_ref)
    local self = setmetatable({}, NativeSettingsIntegration)
    self.settings = settings_ref
    self.nativeSettings = nil
    self.initialized = false
    self.camera = nil
    self.ui = nil
    self.widgetRefs = {}
    -- The master on/off switch is not backed by a single setting - it drives
    -- `enabled` and `position_enabled` together - so it is tracked apart from
    -- widgetRefs, which maps one setting to the one widget that stores it.
    self.masterWidgetRef = nil
    self.settingsObserverUnsubscribe = nil
    return self
end

--- Check if NativeSettings mod is available without initializing
--- @return boolean available Whether NativeSettings mod is installed
function NativeSettingsIntegration.isAvailable()
    local ok, ns = pcall(function()
        return GetMod("nativeSettings") or GetMod("NativeSettings")
    end)
    return ok and ns ~= nil
end

--- Set camera reference so the settings UI can read live tracking state.
--- @param camera_ref table Reference to Camera module instance
function NativeSettingsIntegration:setCamera(camera_ref)
    self.camera = camera_ref
end

--- Set UI reference for showing notifications
--- @param ui_ref table Reference to UI module instance
function NativeSettingsIntegration:setUI(ui_ref)
    self.ui = ui_ref
end

--- Initialize Native Settings integration
--- Silently skips if NativeSettings mod is not installed
--- @return boolean true if NativeSettings is available and registered
function NativeSettingsIntegration:init()
    -- Check if NativeSettings mod is installed
    local ok, ns = pcall(function()
        return GetMod("nativeSettings") or GetMod("NativeSettings")
    end)

    if not ok or not ns then
        -- NativeSettings not installed - this is fine, feature is optional
        return false
    end

    self.nativeSettings = ns
    self:registerSettings()

    -- Subscribe to settings changes to sync UI when changed via hotkey or config file
    self.settingsObserverUnsubscribe = self.settings:observe("*", function(key, new_value, old_value)
        self:onSettingChanged(key, new_value)
    end)

    self.initialized = true
    print("[HeadTracking] Native Settings UI integration enabled")
    return true
end

--- Cleanup and unregister from settings observer
function NativeSettingsIntegration:shutdown()
    if self.settingsObserverUnsubscribe then
        self.settingsObserverUnsubscribe()
        self.settingsObserverUnsubscribe = nil
    end

    -- Clear widget references
    self.widgetRefs = {}
    self.masterWidgetRef = nil
    self.initialized = false
end

--- Handle setting changes from outside NativeSettings (e.g., hotkey toggle)
--- Updates the NativeSettings UI to reflect the new value
--- @param key string Setting key that changed
--- @param new_value any New value
function NativeSettingsIntegration:onSettingChanged(key, new_value)
    if not self.initialized or not self.nativeSettings then
        return
    end

    -- The master switch is the OR of the two tracking keys, so either one
    -- moving has to re-read the pair. It is refreshed alongside - not instead
    -- of - the key's own switch, which falls through below.
    if key == "enabled" or key == "position_enabled" then
        self:refreshWidget(self.masterWidgetRef, self.settings:isTrackingEnabled())
    end

    if ENUM_SETTINGS[key] then
        new_value = enumIndex(key, new_value)
    end

    self:refreshWidget(self.widgetRefs[key], new_value)
end

--- Push a value into one NativeSettings widget.
--- @param widget_ref table|nil Nothing to do when the setting has no widget.
--- @param value any
function NativeSettingsIntegration:refreshWidget(widget_ref, value)
    if not widget_ref then return end
    local ns = self.nativeSettings
    if not ns or not ns.setOption then return end
    local callback = widget_ref.callback
    widget_ref.callback = function() end
    local ok, err = pcall(ns.setOption, widget_ref, value)
    widget_ref.callback = callback
    if not ok then
        print("[HeadTracking] Native Settings UI refresh failed: " .. tostring(err))
    end
end

--- Register all settings with NativeSettings mod
function NativeSettingsIntegration:registerSettings()
    local ns = self.nativeSettings
    if not ns then return end

    -- Create mod settings tab
    ns.addTab("/HeadTracking", "Head Tracking")

    -- =====================================================================
    -- ENABLE/DISABLE TOGGLE
    -- =====================================================================
    -- Master on/off, matching the End hotkey: rotation and position go down
    -- together. It is deliberately NOT widgetRefs["enabled"] - it writes both
    -- keys, so the rotation switch below owns that mapping and this one is
    -- refreshed by hand from isTrackingEnabled().
    self.masterWidgetRef = ns.addSwitch(
        "/HeadTracking",
        "Enable Head Tracking",
        "Master switch for rotation and position together. Hotkey: End / Ctrl+Shift+Y.",
        self.settings:isTrackingEnabled(),
        self.settings:getDefaults().enabled,
        function(state)
            self.settings:setTrackingEnabled(state)
            -- Reset camera when disabling
            if not state and self.camera then
                self.camera:reset()
            end
            -- Show notification
            if self.ui then
                if state then
                    self.ui:showNotification("Head Tracking: ENABLED", 2.0)
                else
                    self.ui:showNotification("Head Tracking: DISABLED", 2.0)
                end
            end
        end
    )
    -- Rotation on its own, so rotation-only and position-only are both
    -- reachable from the panel rather than only from the Page Up cycle.
    self.widgetRefs["enabled"] = ns.addSwitch(
        "/HeadTracking",
        "Rotational Tracking",
        "Look around with your head. Turn this off and leave Positional Tracking on for lean-only. Hotkey: Page Up / Ctrl+Shift+G cycles rotation-only, position-only and both.",
        self.settings:get("enabled"),
        self.settings:getDefaults().enabled,
        function(state)
            if not state and not self.settings:get("position_enabled") then
                self.settings:setTrackingEnabled(false)
            else
                self.settings:set("enabled", state)
            end
            -- Peel any baked head rotation back out, the same as the Page Up
            -- handler does when rotation flips off.
            if not state and self.camera then
                self.camera:reset()
            end
        end
    )
    -- Aim-down-sights behaviour. Same three modes the Insert hotkey cycles.
    do
        local spec = ENUM_SETTINGS.ads_mode
        self.widgetRefs["ads_mode"] = ns.addSelectorString(
            "/HeadTracking",
            "Aiming Down Sights",
            "What happens to head tracking while the sights are up. Raising them always swings the view onto the point the reticle was marking; this picks what follows. Hotkey: Insert / Ctrl+Shift+U.",
            spec.labels,
            enumIndex("ads_mode", self.settings:get("ads_mode")),
            enumIndex("ads_mode", self.settings:getDefaults().ads_mode),
            function(index)
                self.settings:set("ads_mode", spec.values[index])
            end
        )
    end

    -- Yaw mode. The camera has to drop its yaw-mode intermediates on the way
    -- through or the old mode's composition is baked into the new one's base,
    -- which is drift that accumulates per switch - the same call the PageDown
    -- handler makes.
    do
        local spec = ENUM_SETTINGS.yaw_mode
        self.widgetRefs["yaw_mode"] = ns.addSelectorString(
            "/HeadTracking",
            "Yaw Mode",
            "World keeps head yaw swinging around world vertical however far the view is pitched. Camera-relative pivots around the camera's own up-axis, which tilts with mouse pitch. Hotkey: Page Down / Ctrl+Shift+H.",
            spec.labels,
            enumIndex("yaw_mode", self.settings:get("yaw_mode")),
            enumIndex("yaw_mode", self.settings:getDefaults().yaw_mode),
            function(index)
                self.settings:set("yaw_mode", spec.values[index])
                if self.camera and self.camera.prepareYawModeSwitch then
                    self.camera:prepareYawModeSwitch()
                end
            end
        )
    end

    -- =====================================================================
    -- SMOOTHING SECTION
    -- =====================================================================
    ns.addSubcategory("/HeadTracking/Smoothing", "Smoothing")

    -- Local smoothing (tracker on this machine)
    self.widgetRefs["local_smoothing"] = ns.addRangeFloat(
        "/HeadTracking/Smoothing",
        "Local Smoothing",
        "Smoothing applied when the tracker runs on this machine (loopback). 0 = no smoothing, 1 = heavy.",
        0.0, 1.0, 0.05,
        "%.2f",
        self.settings:get("local_smoothing"),
        self.settings:getDefaults().local_smoothing,
        function(value)
            self.settings:set("local_smoothing", value)
        end
    )
    -- Remote smoothing (tracker is a device elsewhere on the network)
    self.widgetRefs["remote_smoothing"] = ns.addRangeFloat(
        "/HeadTracking/Smoothing",
        "Remote Smoothing",
        "Smoothing applied when the tracker is a remote device on the network. 0 = no smoothing, 1 = heavy.",
        0.0, 1.0, 0.05,
        "%.2f",
        self.settings:get("remote_smoothing"),
        self.settings:getDefaults().remote_smoothing,
        function(value)
            self.settings:set("remote_smoothing", value)
        end
    )
    -- =====================================================================
    -- ROTATION LIMITS SECTION
    -- =====================================================================
    ns.addSubcategory("/HeadTracking/Limits", "Rotation Limits")

    -- Yaw clamp
    self.widgetRefs["clamp_yaw"] = ns.addRangeFloat(
        "/HeadTracking/Limits",
        "Max Yaw",
        "Maximum horizontal rotation in degrees (left/right from center).",
        10.0, 180.0, 5.0,
        "%.0f°",
        self.settings:get("clamp_yaw"),
        self.settings:getDefaults().clamp_yaw,
        function(value)
            self.settings:set("clamp_yaw", value)
        end
    )
    -- Pitch clamp
    self.widgetRefs["clamp_pitch"] = ns.addRangeFloat(
        "/HeadTracking/Limits",
        "Max Pitch",
        "Maximum vertical rotation in degrees (up/down from center).",
        10.0, 90.0, 5.0,
        "%.0f°",
        self.settings:get("clamp_pitch"),
        self.settings:getDefaults().clamp_pitch,
        function(value)
            self.settings:set("clamp_pitch", value)
        end
    )
    -- Roll clamp
    self.widgetRefs["clamp_roll"] = ns.addRangeFloat(
        "/HeadTracking/Limits",
        "Max Roll",
        "Maximum tilt rotation in degrees (head tilt left/right).",
        0.0, 90.0, 5.0,
        "%.0f°",
        self.settings:get("clamp_roll"),
        self.settings:getDefaults().clamp_roll,
        function(value)
            self.settings:set("clamp_roll", value)
        end
    )
    -- =====================================================================
    -- POSITION (6DOF) SECTION
    -- =====================================================================
    ns.addSubcategory("/HeadTracking/Position", "Position (6DOF)")

    self.widgetRefs["position_enabled"] = ns.addSwitch(
        "/HeadTracking/Position",
        "Positional Tracking",
        "Lean and peek with your head position, on top of rotation. Hotkey: Page Up / Ctrl+Shift+G cycles rotation-only, position-only and both.",
        self.settings:get("position_enabled"),
        self.settings:getDefaults().position_enabled,
        function(state)
            if not state and not self.settings:get("enabled") then
                self.settings:setTrackingEnabled(false)
            else
                self.settings:set("position_enabled", state)
            end
        end
    )
    -- Z limits are asymmetric because leaning in has far more travel than
    -- pulling back, which stops the camera clipping through the player model.
    local POSITION_WIDGETS = {
        { key = "position_limit_x", label = "Limit X (metres)",
          desc = "Furthest the camera moves sideways, in metres each way.",
          min = 0.0, max = 0.5, step = 0.01, fmt = "%.2f" },
        { key = "position_limit_y_up", label = "Limit Y up (metres)",
          desc = "Furthest the camera rises.",
          min = 0.0, max = 0.5, step = 0.01, fmt = "%.2f" },
        { key = "position_limit_y_down", label = "Limit Y down (metres)",
          desc = "Furthest the camera drops. Separate from the up limit so crouching down can be tighter than standing up.",
          min = 0.0, max = 0.5, step = 0.01, fmt = "%.2f" },
        { key = "position_limit_z_fwd", label = "Limit Z forward (metres)",
          desc = "Furthest the camera leans in.",
          min = 0.0, max = 0.5, step = 0.01, fmt = "%.2f" },
        { key = "position_limit_z_back", label = "Limit Z back (metres)",
          desc = "Furthest the camera pulls back. Deliberately tighter than the forward limit, so pulling back does not clip through V.",
          min = 0.0, max = 0.5, step = 0.01, fmt = "%.2f" },
    }

    for _, w in ipairs(POSITION_WIDGETS) do
        local key = w.key
        self.widgetRefs[key] = ns.addRangeFloat(
            "/HeadTracking/Position", w.label, w.desc,
            w.min, w.max, w.step, w.fmt,
            self.settings:get(key),
            self.settings:getDefaults()[key],
            function(value)
                self.settings:set(key, value)
            end
        )
    end

    -- =====================================================================
    -- CROSSHAIR SECTION
    -- =====================================================================
    ns.addSubcategory("/HeadTracking/Crosshair", "Crosshair Overlay")

    -- Crosshair enabled
    self.widgetRefs["crosshair_enabled"] = ns.addSwitch(
        "/HeadTracking/Crosshair",
        "Enable Crosshair",
        "Move the game's built-in reticle to mark the true aim point when head tracking offsets the view.",
        self.settings:get("crosshair_enabled"),
        self.settings:getDefaults().crosshair_enabled,
        function(state)
            self.settings:set("crosshair_enabled", state)
        end
    )
    -- Crosshair fallback FOV (used only when live FOV from FPPCameraComponent is unavailable)
    self.widgetRefs["crosshair_fov_degrees"] = ns.addRangeFloat(
        "/HeadTracking/Crosshair",
        "Fallback FOV (degrees)",
        "Horizontal FOV used for reticle projection when the live game FOV cannot be read. Match your in-game FOV setting.",
        30.0, 140.0, 1.0,
        "%.0f",
        self.settings:get("crosshair_fov_degrees"),
        self.settings:getDefaults().crosshair_fov_degrees,
        function(value)
            self.settings:set("crosshair_fov_degrees", value)
        end
    )
    -- Reticle forward-extrapolation - compensates dynamic drift during motion
    self.widgetRefs["crosshair_lead_factor"] = ns.addRangeFloat(
        "/HeadTracking/Crosshair",
        "Reticle Lead (frames)",
        "Forward-extrapolates the reticle by N frames of per-frame head delta. 0 = use latest head rotation (correct at rest). Bump up if reticle drifts in head-motion direction during motion and settles correct at rest. At rest the lead collapses to zero, so the rest position never shifts.",
        0.0, 2.0, 0.05,
        "%.2f",
        self.settings:get("crosshair_lead_factor"),
        self.settings:getDefaults().crosshair_lead_factor,
        function(value)
            self.settings:set("crosshair_lead_factor", value)
        end
    )
    -- Network section removed: UDP 4242 is owned by the native RED4ext plugin,
    -- nothing here is user-configurable. Point OpenTrack at 127.0.0.1:4242.

    -- =====================================================================
    -- ACTIONS SECTION
    -- =====================================================================
    ns.addSubcategory("/HeadTracking/Actions", "Actions")

    -- Reset all settings button
    ns.addButton(
        "/HeadTracking/Actions",
        "Reset All Settings",
        "Reset all head tracking settings to their default values.",
        "Reset to Defaults",
        45,
        function()
            self:resetAllSettings()
        end
    )
end

--- Reset all settings to defaults and refresh NativeSettings UI
function NativeSettingsIntegration:resetAllSettings()
    -- Reset settings (will trigger observer notifications)
    self.settings:resetAll()

    -- Reset camera state
    if self.camera then
        self.camera:reset()
    end

    -- Show notification
    if self.ui then
        self.ui:showNotification("Head Tracking: Settings reset to defaults", 3.0)
    end

    print("[HeadTracking] All settings reset to defaults via Native Settings")
end

--- Check if NativeSettings integration is active
--- @return boolean initialized Whether integration is active
function NativeSettingsIntegration:isInitialized()
    return self.initialized
end

--- Get the NativeSettings mod reference (for advanced usage)
--- @return table|nil nativeSettings The NativeSettings mod or nil
function NativeSettingsIntegration:getNativeSettings()
    return self.nativeSettings
end

return NativeSettingsIntegration
