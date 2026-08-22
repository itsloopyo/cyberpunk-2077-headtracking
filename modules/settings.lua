-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Settings Module
-- Manages persistent configuration via config.json
-- Production-ready implementation with validation, observers, and atomic saves

local Settings = {}
Settings.__index = Settings

-- Allowed yaw_mode strings. Kept as a set so :set() can validate the same
-- way load() already does, and a bad value never reaches anywhere that
-- branches on it (camera.lua / nativesettings.lua).
local YAW_MODE_VALUES = { world = true, ["local"] = true }

-- Allowed ads_mode strings, same reasoning as YAW_MODE_VALUES. Cycled with
-- Insert / Ctrl+Shift+U; state.lua and init.lua branch on all three. Every mode
-- makes the same swing onto the aim point when the sights come up; they differ
-- in what happens for the rest of the aim.
--   "paused"  - stand tracking down and hand the view back to the game.
--   "marker"  - keep tracking, and draw an aim marker at the projected hit
--               point, since the game hides its crosshair with the sights up.
--   "tracked" - keep tracking, no marker.
local ADS_MODE_VALUES = { paused = true, marker = true, tracked = true }

-- Which tracking mode the master switch restores. Recorded when tracking is
-- switched off and read back when it is switched on, so End -> quit -> relaunch
-- -> End returns to the mode the player was in rather than forcing 6DOF.
-- Persisted state rather than a knob: nothing in the settings panel shows it.
local SAVED_TRACKING_MODE_VALUES = { both = true, rot = true, pos = true }

-- Validation rules for each setting
local VALIDATION_RULES = {
    enabled = { type = "boolean" },
    -- Smoothing is two parameters, picked per connection by source address.
    -- Both cover rotation and position; there is no separate position
    -- smoothing setting.
    local_smoothing = { type = "number", min = 0.0, max = 1.0 },
    remote_smoothing = { type = "number", min = 0.0, max = 1.0 },
    -- "Soft Look" rotation caps (per-axis, degrees). These are a Cyberpunk-
    -- specific safety limit to keep head rotation from fighting the aim
    -- system, not the CameraUnlock position limits.
    clamp_yaw = { type = "number", min = 10.0, max = 180.0 },
    clamp_pitch = { type = "number", min = 10.0, max = 90.0 },
    clamp_roll = { type = "number", min = 0.0, max = 90.0 },
    -- Crosshair settings
    crosshair_enabled = { type = "boolean" },
    -- Position tracking and Cyberpunk-specific camera travel limits.
    position_enabled = { type = "boolean" },
    position_limit_x = { type = "number", min = 0.0, max = 0.5 },
    position_limit_y_up = { type = "number", min = 0.0, max = 0.5 },
    position_limit_y_down = { type = "number", min = 0.0, max = 0.5 },
    position_limit_z_fwd = { type = "number", min = 0.0, max = 0.5 },
    position_limit_z_back = { type = "number", min = 0.0, max = 0.5 },
    -- Yaw mode: "world" (default, horizon-locked world-space yaw) or "local"
    -- (legacy camera-local yaw that tilts with mouse pitch). See camera.lua.
    yaw_mode = { type = "string" },
    -- What aiming down sights does to the view. See ADS_MODE_VALUES.
    ads_mode = { type = "string" },
    -- Tracking mode the master switch restores. See SAVED_TRACKING_MODE_VALUES.
    saved_tracking_mode = { type = "string" },
    -- Diagnostic: write CLEAN (mouse-only) orientation to cam.localOrientation
    -- instead of head-rotated. Used to probe which engine systems read
    -- cam+0xD0 for their "where is the camera pointing" answer. See
    -- modules/camera.lua and Camera:apply().
    decouple_diag_clean_cam = { type = "boolean" },
}

-- Keys that used to hold the single smoothing value, in the order they are
-- reported. Both are still sitting in every config.json written before the
-- split, and both are now ignored.
local RETIRED_SMOOTHING_KEYS = { "smoothing_factor", "position_smoothing" }

local RETIRED_TRACKER_SHAPING_KEYS = {
    "sensitivity_yaw", "sensitivity_pitch", "sensitivity_roll",
    "deadzone_yaw", "deadzone_pitch", "deadzone_roll",
    "position_sens_x", "position_sens_y", "position_sens_z",
}

local RETIRED_CROSSHAIR_PROJECTION_KEYS = {
    "crosshair_fov_degrees", "crosshair_lead_factor",
}

-- Warned once per session rather than once per load: settings are re-read when
-- the mod hot-reloads, and repeating this every time buries it in the log.
local warned_retired_smoothing_key = false

--- Say once that a retired smoothing key in config.json is being ignored.
--- Without this the key is dropped in silence: the user's tuned value reverts
--- to a default they never picked, while the dead line is still in their
--- config.json arguing that they did pick it.
---
--- The old value is deliberately NOT migrated into local_smoothing or
--- remote_smoothing. It carried a hidden 0.15 floor, so the number in an
--- existing config does not mean what it used to: copying 0.5 across would hand
--- a same-machine user smoothing they never chose under the new semantics, and
--- copying it into only one of the two would be a guess about which connection
--- they were on.
--- @param loaded table Raw decoded config.json contents
--- @param defaults table Current default values, so the quoted defaults in the
---        message cannot drift away from the ones actually applied
--- @return string|nil message The warning that was printed, or nil if none was
local function warnRetiredSmoothingKeys(loaded, defaults)
    -- Guard order is load-bearing. The one-shot is checked BEFORE presence, so
    -- a config without these keys can never consume the single warning and
    -- leave a later load that does have them silent.
    if warned_retired_smoothing_key then
        return nil
    end

    local present = {}
    for _, key in ipairs(RETIRED_SMOOTHING_KEYS) do
        if loaded[key] ~= nil then
            present[#present + 1] = "'" .. key .. "'"
        end
    end
    if #present == 0 then
        return nil
    end

    warned_retired_smoothing_key = true

    local many = #present > 1
    local message = "[HeadTracking] Config " .. (many and "keys " or "key ")
        .. table.concat(present, " and ") .. (many and " have" or " has")
        .. " been retired and " .. (many and "are" or "is") .. " IGNORED."
        .. " Smoothing is now two keys: 'local_smoothing' (default "
        .. tostring(defaults.local_smoothing) .. ", applies to a tracker on this"
        .. " machine) and 'remote_smoothing' (default "
        .. tostring(defaults.remote_smoothing) .. ", applies to a tracker on the"
        .. " network). The old value is not migrated because the semantics changed -"
        .. " it carried a hidden " .. tostring(defaults.remote_smoothing) .. " floor"
        .. " that no longer exists. Set the two new keys."
    print(message)
    return message
end

--- Validate a single value against its rule
--- @param key string Setting key
--- @param value any Value to validate
--- @return boolean valid Whether value is valid
--- @return any corrected_value Corrected value if invalid, or original if valid
local function validateValue(key, value)
    local rule = VALIDATION_RULES[key]
    if not rule then
        return false, nil
    end

    -- Type check
    if type(value) ~= rule.type then
        return false, nil
    end

    -- Number range validation
    if rule.type == "number" then
        -- NaN check
        if value ~= value then
            return false, nil
        end

        -- Integer check
        if rule.integer and math.floor(value) ~= value then
            value = math.floor(value)
        end

        -- Clamp to valid range
        if rule.min and value < rule.min then
            return false, rule.min
        end
        if rule.max and value > rule.max then
            return false, rule.max
        end
    end

    -- String enum validation. Both string-typed settings are branched on by
    -- name elsewhere (camera.lua reads yaw_mode as a binary "world" / "local",
    -- state.lua and init.lua read ads_mode as one of three), so an unknown
    -- value would silently fall through to whichever branch is last.
    if rule.type == "string" and key == "yaw_mode" then
        if not YAW_MODE_VALUES[value] then
            return false, nil
        end
    end

    if rule.type == "string" and key == "ads_mode" then
        if not ADS_MODE_VALUES[value] then
            return false, nil
        end
    end

    if rule.type == "string" and key == "saved_tracking_mode" then
        if not SAVED_TRACKING_MODE_VALUES[value] then
            return false, nil
        end
    end

    return true, value
end

--- Create a new settings instance with default values
--- @return table Settings instance
function Settings.new()
    local self = setmetatable({}, Settings)

    -- Default configuration values (CameraUnlock standard unless noted)
    self.defaults = {
        enabled = true,
        -- Smoothing applied when the tracker runs on this machine
        -- (loopback). 0 = no smoothing, 1 = heavy.
        local_smoothing = 0.0,
        -- Smoothing applied when the tracker is a remote device on the
        -- network. 0 = no smoothing, 1 = heavy.
        remote_smoothing = 0.15,
        -- "Soft Look" rotation caps (Cyberpunk-specific, not CameraUnlock position limits)
        clamp_yaw = 120.0,
        clamp_pitch = 80.0,
        clamp_roll = 45.0,
        -- Crosshair overlay
        crosshair_enabled = true,
        -- Position tracking (6DOF)
        position_enabled = true,
        position_limit_x = 0.30,
        position_limit_y_up = 0.20,
        position_limit_y_down = 0.05,
        position_limit_z_fwd = 0.40,
        position_limit_z_back = 0.10,
        -- Yaw mode: "world" (default) = horizon-locked yaw. Head yaw always
        -- rotates around the world-vertical axis regardless of where the
        -- mouse is pitched, so the horizon stays where yaw lives.
        -- "local" = legacy camera-tilted yaw (rotates around the camera's
        -- current local-up axis, which tilts with mouse pitch).
        -- Toggle between them with PageDown / Ctrl+Shift+H.
        yaw_mode = "world",
        -- Aiming down sights hands the view back to the game by default, so
        -- the sights land on the point the reticle was marking. Insert /
        -- Ctrl+Shift+U cycles to "marker" then "tracked".
        ads_mode = "paused",
        -- Mode the master switch restores; rewritten every time tracking is
        -- switched off. Not shown in the settings panel.
        saved_tracking_mode = "both",
        -- Clean-camera diagnostic path. Lua keeps cam.localOrientation
        -- mouse-only while native experiments try to inject head rotation.
        decouple_diag_clean_cam = false,
    }

    -- Current values (populated by load())
    self.values = {}

    -- Observer callbacks for setting changes
    -- Table of key -> { callback1, callback2, ... }
    self.observers = {}

    -- Config file path (relative to mod directory)
    self.path = "config.json"

    -- Track if we have unsaved changes (for batched saves)
    self.dirty = false

    -- Initialized flag
    self.initialized = false

    return self
end

--- Load settings from config.json
--- If file is missing or corrupted, creates new file with defaults
--- @return boolean true if file was loaded, false if defaults were used
function Settings:load()
    local loaded_from_file = false
    local file = io.open(self.path, "r")

    if file then
        local content = file:read("*all")
        file:close()

        if content and #content > 0 then
            -- Attempt to parse JSON
            local ok, loaded = pcall(json.decode, content)
            if ok and type(loaded) == "table" then
                -- Drop obsolete port keys from pre-4242-unification configs.
                -- udp_port was the old OpenTrack listen port on the Lua side;
                -- bridge_tcp_port was the Python-bridge / native-plugin TCP
                -- port. Both are gone now - OpenTrack UDP goes straight to the
                -- native plugin on 4242 and the native plugin serves Lua on
                -- TCP 4242. Users don't need to do anything; we just ignore
                -- the stale keys so they don't fail validation.
                if loaded.udp_port ~= nil then
                    print("[HeadTracking] Ignoring obsolete 'udp_port' in config.json (port is hardcoded to 4242 now)")
                    loaded.udp_port = nil
                end
                if loaded.bridge_tcp_port ~= nil then
                    print("[HeadTracking] Ignoring obsolete 'bridge_tcp_port' in config.json (port is hardcoded to 4242 now)")
                    loaded.bridge_tcp_port = nil
                end
                -- Drop obsolete experimental yaw modes (world_simple, world_flip
                -- were diagnostic attempts; world_simple crashed the game). Map
                -- anything that isn't "local" to "world".
                if loaded.yaw_mode ~= nil and loaded.yaw_mode ~= "world" and loaded.yaw_mode ~= "local" then
                    print("[HeadTracking] Resetting unknown yaw_mode '" .. tostring(loaded.yaw_mode) .. "' to 'world'")
                    loaded.yaw_mode = "world"
                end

                -- Retired smoothing keys. Unlike the obsolete port keys above
                -- these are not nil'd out: the merge below only walks
                -- self.defaults, so they are already ignored. What was missing
                -- was any word to the user that their tuned value is gone.
                warnRetiredSmoothingKeys(loaded, self.defaults)

                local removed_tracker_keys = {}
                for _, key in ipairs(RETIRED_TRACKER_SHAPING_KEYS) do
                    if loaded[key] ~= nil then
                        loaded[key] = nil
                        removed_tracker_keys[#removed_tracker_keys + 1] = key
                    end
                end

                local removed_projection_keys = {}
                for _, key in ipairs(RETIRED_CROSSHAIR_PROJECTION_KEYS) do
                    if loaded[key] ~= nil then
                        loaded[key] = nil
                        removed_projection_keys[#removed_projection_keys + 1] = key
                    end
                end

                -- Merge and validate loaded values with defaults
                for k, default_value in pairs(self.defaults) do
                    local loaded_value = loaded[k]
                    if loaded_value ~= nil then
                        local valid, corrected = validateValue(k, loaded_value)
                        if valid then
                            -- Use the validated value, not the raw input: for
                            -- integer-typed settings validateValue floors it,
                            -- and that floored value is the one we must store.
                            self.values[k] = corrected
                        else
                            -- Use corrected value if available, otherwise default
                            self.values[k] = corrected or default_value
                            print("[HeadTracking] Invalid setting '" .. k .. "', using default: " .. tostring(self.values[k]))
                        end
                    else
                        self.values[k] = default_value
                    end
                end
                loaded_from_file = true
                if #removed_tracker_keys > 0 then
                    print("[HeadTracking] Removed tracker-owned settings from config.json: "
                        .. table.concat(removed_tracker_keys, ", "))
                end
                if #removed_projection_keys > 0 then
                    print("[HeadTracking] Removed obsolete reticle projection settings from config.json: "
                        .. table.concat(removed_projection_keys, ", "))
                end
                if #removed_tracker_keys > 0 or #removed_projection_keys > 0 then
                    if not self:save() then
                        error("[HeadTracking] Failed to remove obsolete settings from config.json")
                    end
                end
            else
                print("[HeadTracking] Failed to parse config.json: " .. tostring(loaded))
            end
        end
    end

    if not loaded_from_file then
        -- File missing or corrupted - use defaults
        for k, v in pairs(self.defaults) do
            self.values[k] = v
        end
        -- Create default config file
        self:save()
    end

    self.initialized = true
    return loaded_from_file
end

--- Save current settings to config.json (atomic write)
--- @return boolean success Whether save succeeded
function Settings:save()
    local ok, content = pcall(json.encode, self.values)
    if not ok then
        print("[HeadTracking] Failed to encode settings: " .. tostring(content))
        return false
    end

    -- Write to temporary file first.
    local temp_path = self.path .. ".tmp"
    local file = io.open(temp_path, "w")
    if not file then
        print("[HeadTracking] Failed to open temp file for writing: " .. temp_path)
        return false
    end

    local write_ok = file:write(content)
    file:close()

    if not write_ok then
        print("[HeadTracking] Failed to write config data")
        os.remove(temp_path)
        return false
    end

    -- Crash-safe rename. The previous remove+rename pair had a window where a
    -- crash between the two left the user with no config (and no backup).
    -- Now: rotate the existing file to .bak first, attempt the rename, and on
    -- failure restore from .bak so the user always ends up with either the
    -- new file or their previous one - never nothing.
    local backup_path = self.path .. ".bak"
    -- Probe existence without holding a handle: on Windows an open read
    -- handle prevents os.rename of the same path, which would silently
    -- fail the backup rotation below.
    local probe = io.open(self.path, "r")
    local original_existed = probe ~= nil
    if probe then probe:close() end
    if original_existed then
        os.remove(backup_path)  -- discard previous backup
        local backup_ok = os.rename(self.path, backup_path)
        if not backup_ok then
            print("[HeadTracking] Failed to rotate previous config to backup; aborting save")
            os.remove(temp_path)
            return false
        end
    end

    local rename_ok = os.rename(temp_path, self.path)
    if not rename_ok then
        print("[HeadTracking] Failed to rename temp config file")
        if original_existed then
            -- Restore the previous config so the user isn't left empty-handed.
            os.rename(backup_path, self.path)
        end
        os.remove(temp_path)
        return false
    end

    self.dirty = false
    return true
end

--- Get a setting value
--- @param key string Setting key name
--- @return any Setting value or nil if key doesn't exist
function Settings:get(key)
    if self.values[key] ~= nil then
        return self.values[key]
    end
    return self.defaults[key]
end

--- Set a setting value with validation and auto-save
--- @param key string Setting key name
--- @param value any New value for the setting
--- @return boolean success Whether the value was set
function Settings:set(key, value)
    -- Validate key exists in defaults
    if self.defaults[key] == nil then
        print("[HeadTracking] Unknown setting key: " .. tostring(key))
        return false
    end

    -- Validate and potentially correct value
    local valid, corrected = validateValue(key, value)
    if valid then
        -- Adopt the validated value: integer-typed settings are floored by
        -- validateValue, and that floored result is what must be stored.
        value = corrected
    else
        if corrected ~= nil then
            value = corrected
            print("[HeadTracking] Setting '" .. key .. "' clamped to: " .. tostring(value))
        else
            print("[HeadTracking] Invalid value for '" .. key .. "': " .. tostring(value))
            return false
        end
    end

    -- Check if value actually changed
    local old_value = self.values[key]
    if old_value == value then
        return true
    end

    -- Update value
    self.values[key] = value
    self.dirty = true

    -- Notify observers
    self:notifyObservers(key, value, old_value)

    -- Auto-save
    self:save()

    return true
end

--- Is head tracking on at all (rotation or position)?
--- @return boolean
function Settings:isTrackingEnabled()
    return (self:get("enabled") or self:get("position_enabled")) and true or false
end

--- Master on/off for head tracking, covering rotation AND position.
---
--- Rotation and position live in two settings because the mode hotkey cycles
--- between them, so switching tracking off remembers which mode was in force
--- and switching it back on restores that mode rather than forcing 6DOF. The
--- memory is persisted (saved_tracking_mode), so it also survives a restart.
--- @param on boolean
function Settings:setTrackingEnabled(on)
    if on then
        local mode = self:get("saved_tracking_mode")
        self:set("enabled", mode ~= "pos")
        self:set("position_enabled", mode ~= "rot")
    else
        -- Only record a mode that was actually live. Switching off something
        -- already off would otherwise persist "both" over the real memory.
        if self:isTrackingEnabled() then
            local rot = self:get("enabled") and true or false
            local pos = self:get("position_enabled") and true or false
            self:set("saved_tracking_mode", (rot and pos) and "both" or (rot and "rot" or "pos"))
        end
        self:set("enabled", false)
        self:set("position_enabled", false)
    end
end

--- Bring a freshly loaded config up into the state a session starts in.
---
--- Called once from init.lua, straight after :load(). Everything it does NOT
--- touch is therefore persisted as-is - most of the config, including yaw_mode
--- and ads_mode, both of which are settings the player sets from the panel or a
--- hotkey and would be silently discarded if this reset them.
---
--- What it does touch, and why:
---   * Tracking comes up ON, so a session that ended with End pressed does not
---     start the next one doing nothing. Which MODE it comes up in is the
---     player's: setTrackingEnabled reads the persisted saved_tracking_mode, so
---     quitting in rotation-only comes back in rotation-only. A config that is
---     already tracking is left alone, because the pair it holds IS the live
---     mode from last session.
---   * The reticle driver comes up on for the same reason.
---   * decouple_diag_clean_cam is a reverse-engineering diagnostic that hands
---     the view to an experimental native path. It is off every launch so a
---     config left mid-investigation cannot ship a broken camera into normal
---     play.
function Settings:applyLaunchState()
    if not self:isTrackingEnabled() then
        self:setTrackingEnabled(true)
    end
    self:set("crosshair_enabled", true)
    self:set("decouple_diag_clean_cam", false)
end

--- Get all current setting values as a table copy
--- @return table Copy of all current settings
function Settings:getAll()
    local copy = {}
    for k, v in pairs(self.values) do
        copy[k] = v
    end
    return copy
end

--- Get all default values as a table copy
--- @return table Copy of all default settings
function Settings:getDefaults()
    local copy = {}
    for k, v in pairs(self.defaults) do
        copy[k] = v
    end
    return copy
end

--- Reset a specific setting to its default value
--- @param key string Setting key to reset
--- @return boolean success Whether reset succeeded
function Settings:reset(key)
    if self.defaults[key] == nil then
        print("[HeadTracking] Unknown setting key: " .. tostring(key))
        return false
    end

    return self:set(key, self.defaults[key])
end

--- Reset all settings to defaults
--- @return boolean success Whether reset succeeded
function Settings:resetAll()
    local old_values = {}
    for k, v in pairs(self.values) do
        old_values[k] = v
    end

    for k, v in pairs(self.defaults) do
        self.values[k] = v
    end

    -- Notify all observers of changes
    for k, new_value in pairs(self.values) do
        local old_value = old_values[k]
        if old_value ~= new_value then
            self:notifyObservers(k, new_value, old_value)
        end
    end

    self.dirty = true
    return self:save()
end

--- Register an observer callback for setting changes
--- @param key string|"*" Setting key to watch, or "*" for all changes
--- @param callback function Callback(key, new_value, old_value)
--- @return function unsubscribe Function to remove this observer
function Settings:observe(key, callback)
    if type(callback) ~= "function" then
        print("[HeadTracking] Observer callback must be a function")
        return function() end
    end

    if not self.observers[key] then
        self.observers[key] = {}
    end

    table.insert(self.observers[key], callback)

    -- Return unsubscribe function
    return function()
        self:removeObserver(key, callback)
    end
end

--- Remove an observer callback
--- @param key string Setting key
--- @param callback function Callback to remove
function Settings:removeObserver(key, callback)
    local observers = self.observers[key]
    if not observers then return end

    for i, cb in ipairs(observers) do
        if cb == callback then
            table.remove(observers, i)
            return
        end
    end
end

--- Notify all observers of a setting change
--- @param key string Setting key that changed
--- @param new_value any New value
--- @param old_value any Previous value
function Settings:notifyObservers(key, new_value, old_value)
    -- Notify key-specific observers
    local key_observers = self.observers[key]
    if key_observers then
        for _, callback in ipairs(key_observers) do
            local ok, err = pcall(callback, key, new_value, old_value)
            if not ok then
                print("[HeadTracking] Observer error for '" .. key .. "': " .. tostring(err))
            end
        end
    end

    -- Notify wildcard observers
    local wildcard_observers = self.observers["*"]
    if wildcard_observers then
        for _, callback in ipairs(wildcard_observers) do
            local ok, err = pcall(callback, key, new_value, old_value)
            if not ok then
                print("[HeadTracking] Observer error for '*': " .. tostring(err))
            end
        end
    end
end

--- Check if a setting key is valid
--- @param key string Setting key to check
--- @return boolean valid Whether key exists
function Settings:isValidKey(key)
    return self.defaults[key] ~= nil
end

--- Get validation rules for a setting
--- @param key string Setting key
--- @return table|nil rules Validation rules or nil if key doesn't exist
function Settings:getValidationRules(key)
    return VALIDATION_RULES[key]
end

--- Check if settings have been initialized
--- @return boolean initialized Whether load() has been called
function Settings:isInitialized()
    return self.initialized
end

return Settings
