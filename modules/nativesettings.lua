-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Native Settings UI Integration Module
-- Optional integration with the NativeSettings mod for in-game configuration
-- https://www.nexusmods.com/cyberpunk2077/mods/3518
-- Production-ready implementation with state sync, reset functionality, and observer integration

local NativeSettingsIntegration = {}
NativeSettingsIntegration.__index = NativeSettingsIntegration

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
    self.settingsObserverUnsubscribe = nil
    return self
end

--- Check if NativeSettings mod is available without initializing
--- @return boolean available Whether NativeSettings mod is installed
function NativeSettingsIntegration.isAvailable()
    local ok, ns = pcall(function()
        return GetMod("NativeSettings")
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
        return GetMod("NativeSettings")
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

    -- The Enabled switch is the master on/off, so it covers rotation and
    -- position together. Either key moving has to re-read the pair, and
    -- position_enabled has no widget of its own to look up.
    if key == "enabled" or key == "position_enabled" then
        key = "enabled"
        new_value = self.settings:isTrackingEnabled()
    end

    -- Map settings key to NativeSettings widget path
    local widget_path = self.widgetRefs[key]
    if not widget_path then
        return
    end

    -- NativeSettings provides refresh methods to update widget display
    local ns = self.nativeSettings
    if ns.refresh then
        local refresh_ok, refresh_err = pcall(function()
            ns.refresh(widget_path, new_value)
        end)
        if not refresh_ok then
            -- NativeSettings might not support refresh on all widgets - this is OK
        end
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
    ns.addSwitch(
        "/HeadTracking/Enabled",
        "Enable Head Tracking",
        "Toggle head tracking on/off. Can also use hotkey (default: End)",
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
    self.widgetRefs["enabled"] = "/HeadTracking/Enabled"

    -- =====================================================================
    -- SENSITIVITY SECTION
    -- =====================================================================
    ns.addSubcategory("/HeadTracking/Sensitivity", "Sensitivity")

    -- Yaw sensitivity
    ns.addRangeFloat(
        "/HeadTracking/Sensitivity/Yaw",
        "Yaw Sensitivity",
        "Horizontal rotation sensitivity (left/right). Higher = more responsive.",
        0.1, 3.0, 0.1,
        "%.1f",
        self.settings:get("sensitivity_yaw"),
        self.settings:getDefaults().sensitivity_yaw,
        function(value)
            self.settings:set("sensitivity_yaw", value)
        end
    )
    self.widgetRefs["sensitivity_yaw"] = "/HeadTracking/Sensitivity/Yaw"

    -- Pitch sensitivity
    ns.addRangeFloat(
        "/HeadTracking/Sensitivity/Pitch",
        "Pitch Sensitivity",
        "Vertical rotation sensitivity (up/down). Higher = more responsive.",
        0.1, 3.0, 0.1,
        "%.1f",
        self.settings:get("sensitivity_pitch"),
        self.settings:getDefaults().sensitivity_pitch,
        function(value)
            self.settings:set("sensitivity_pitch", value)
        end
    )
    self.widgetRefs["sensitivity_pitch"] = "/HeadTracking/Sensitivity/Pitch"

    -- Roll sensitivity
    ns.addRangeFloat(
        "/HeadTracking/Sensitivity/Roll",
        "Roll Sensitivity",
        "Tilt rotation sensitivity (head tilt). Set to 0 to disable roll.",
        0.0, 2.0, 0.1,
        "%.1f",
        self.settings:get("sensitivity_roll"),
        self.settings:getDefaults().sensitivity_roll,
        function(value)
            self.settings:set("sensitivity_roll", value)
        end
    )
    self.widgetRefs["sensitivity_roll"] = "/HeadTracking/Sensitivity/Roll"

    -- =====================================================================
    -- SMOOTHING SECTION
    -- =====================================================================
    ns.addSubcategory("/HeadTracking/Smoothing", "Smoothing")

    -- Local smoothing (tracker on this machine)
    ns.addRangeFloat(
        "/HeadTracking/Smoothing/Local",
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
    self.widgetRefs["local_smoothing"] = "/HeadTracking/Smoothing/Local"

    -- Remote smoothing (tracker is a device elsewhere on the network)
    ns.addRangeFloat(
        "/HeadTracking/Smoothing/Remote",
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
    self.widgetRefs["remote_smoothing"] = "/HeadTracking/Smoothing/Remote"

    -- =====================================================================
    -- ROTATION LIMITS SECTION
    -- =====================================================================
    ns.addSubcategory("/HeadTracking/Limits", "Rotation Limits")

    -- Yaw clamp
    ns.addRangeFloat(
        "/HeadTracking/Limits/Yaw",
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
    self.widgetRefs["clamp_yaw"] = "/HeadTracking/Limits/Yaw"

    -- Pitch clamp
    ns.addRangeFloat(
        "/HeadTracking/Limits/Pitch",
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
    self.widgetRefs["clamp_pitch"] = "/HeadTracking/Limits/Pitch"

    -- Roll clamp
    ns.addRangeFloat(
        "/HeadTracking/Limits/Roll",
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
    self.widgetRefs["clamp_roll"] = "/HeadTracking/Limits/Roll"

    -- =====================================================================
    -- DEADZONES SECTION
    -- =====================================================================
    ns.addSubcategory("/HeadTracking/Deadzones", "Deadzones")

    ns.addRangeFloat(
        "/HeadTracking/Deadzones/Yaw",
        "Yaw Deadzone",
        "Degrees of horizontal tracker noise ignored. Raise if the view drifts left/right when your head is still.",
        0.0, 5.0, 0.1,
        "%.1f°",
        self.settings:get("deadzone_yaw"),
        self.settings:getDefaults().deadzone_yaw,
        function(value) self.settings:set("deadzone_yaw", value) end
    )
    self.widgetRefs["deadzone_yaw"] = "/HeadTracking/Deadzones/Yaw"

    ns.addRangeFloat(
        "/HeadTracking/Deadzones/Pitch",
        "Pitch Deadzone",
        "Degrees of vertical tracker noise ignored. Raise if the view drifts up/down when your head is still.",
        0.0, 5.0, 0.1,
        "%.1f°",
        self.settings:get("deadzone_pitch"),
        self.settings:getDefaults().deadzone_pitch,
        function(value) self.settings:set("deadzone_pitch", value) end
    )
    self.widgetRefs["deadzone_pitch"] = "/HeadTracking/Deadzones/Pitch"

    ns.addRangeFloat(
        "/HeadTracking/Deadzones/Roll",
        "Roll Deadzone",
        "Degrees of head-tilt tracker noise ignored. Raise if the view gradually rolls when your head is still.",
        0.0, 5.0, 0.1,
        "%.1f°",
        self.settings:get("deadzone_roll"),
        self.settings:getDefaults().deadzone_roll,
        function(value) self.settings:set("deadzone_roll", value) end
    )
    self.widgetRefs["deadzone_roll"] = "/HeadTracking/Deadzones/Roll"

    -- =====================================================================
    -- CROSSHAIR SECTION
    -- =====================================================================
    ns.addSubcategory("/HeadTracking/Crosshair", "Crosshair Overlay")

    -- Crosshair enabled
    ns.addSwitch(
        "/HeadTracking/Crosshair/Enabled",
        "Enable Crosshair",
        "Move the game's built-in reticle to mark the true aim point when head tracking offsets the view.",
        self.settings:get("crosshair_enabled"),
        self.settings:getDefaults().crosshair_enabled,
        function(state)
            self.settings:set("crosshair_enabled", state)
        end
    )
    self.widgetRefs["crosshair_enabled"] = "/HeadTracking/Crosshair/Enabled"

    -- Crosshair fallback FOV (used only when live FOV from FPPCameraComponent is unavailable)
    ns.addRangeFloat(
        "/HeadTracking/Crosshair/FovDegrees",
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
    self.widgetRefs["crosshair_fov_degrees"] = "/HeadTracking/Crosshair/FovDegrees"

    -- Reticle forward-extrapolation - compensates dynamic drift during motion
    ns.addRangeFloat(
        "/HeadTracking/Crosshair/LeadFactor",
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
    self.widgetRefs["crosshair_lead_factor"] = "/HeadTracking/Crosshair/LeadFactor"

    -- Network section removed: UDP 4242 is owned by the native RED4ext plugin,
    -- nothing here is user-configurable. Point OpenTrack at 127.0.0.1:4242.

    -- =====================================================================
    -- ACTIONS SECTION
    -- =====================================================================
    ns.addSubcategory("/HeadTracking/Actions", "Actions")

    -- Reset all settings button
    ns.addButton(
        "/HeadTracking/Actions/ResetAll",
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
