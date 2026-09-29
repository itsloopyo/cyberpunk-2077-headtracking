-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo

local Settings = {}
Settings.__index = Settings

local function response(raw)
    local result = json.decode(raw)
    if result.error then error(result.error) end
    return result
end

function Settings.new()
    return setmetatable({ values = {}, defaults = {}, observers = {}, initialized = false, pendingSaves = 0 }, Settings)
end

function Settings:load()
    local loaded = response(Game.HeadTrackingLoadConfig())
    self.values = loaded.values
    self.defaults = loaded.defaults
    self.message = loaded.message
    self.status = loaded.status
    self.initialized = true
    return loaded.status == "Canonical" or loaded.status == "Migrated"
end

function Settings:get(key)
    return self.values[key]
end

function Settings:apply(changes, persist)
    if persist then
        local result = response(Game.HeadTrackingSaveConfig(json.encode(changes)))
        self.message = result.message
        if result.pending then
            self.pendingSaves = self.pendingSaves + 1
        elseif not result.saved then
            print("[HeadTracking] " .. result.message)
            if self.onStatus then self.onStatus(result.message) end
        end
    end
    local previous = self.values
    local values = self:getAll()
    for key, value in pairs(changes) do values[key] = value end
    self.values = values
    for key, value in pairs(changes) do
        if previous[key] ~= value then self:notifyObservers(key, value, previous[key]) end
    end
    return true
end

function Settings:update()
    if self.pendingSaves == 0 then return end
    for _, result in ipairs(response(Game.HeadTrackingConfigStatus()).results) do
        self.pendingSaves = self.pendingSaves - 1
        self.message = result.message
        if not result.saved or result.message ~= "" then
            print("[HeadTracking] " .. result.message)
            if self.onStatus then self.onStatus(result.message) end
        end
    end
end

function Settings:set(key, value)
    if key == "enabled" then return self:setMode(value, self:get("position_enabled")) end
    if key == "position_enabled" then return self:setMode(self:get("enabled"), value) end
    if key == "enable_on_startup" or self.defaults[key] == nil then
        error("Unknown or read-only setting: " .. tostring(key))
    end
    return self:apply({ [key] = value }, true)
end

function Settings:setMode(rotation, position)
    if not rotation and not position then return self:setTrackingEnabled(false) end
    self.suspendedMode = nil
    return self:apply({ enabled = rotation, position_enabled = position }, true)
end

function Settings:isTrackingEnabled()
    return self:get("enabled") or self:get("position_enabled")
end

function Settings:setTrackingEnabled(on)
    if on then
        if self.suspendedMode then
            local mode = self.suspendedMode
            self.suspendedMode = nil
            return self:apply(mode, false)
        end
    elseif self:isTrackingEnabled() then
        self.suspendedMode = { enabled = self:get("enabled"), position_enabled = self:get("position_enabled") }
        return self:apply({ enabled = false, position_enabled = false }, false)
    end
    return true
end

function Settings:applyLaunchState()
    if not self:get("enable_on_startup") then self:setTrackingEnabled(false) end
end

function Settings:getAll()
    local copy = {}
    for key, value in pairs(self.values) do copy[key] = value end
    return copy
end

function Settings:getDefaults()
    local copy = {}
    for key, value in pairs(self.defaults) do copy[key] = value end
    return copy
end

function Settings:reset(key)
    return self:set(key, self.defaults[key])
end

function Settings:resetAll()
    local changes = self:getDefaults()
    changes.enable_on_startup = nil
    self.suspendedMode = nil
    return self:apply(changes, true)
end

function Settings:observe(key, callback)
    assert(type(callback) == "function", "Setting observer must be a function")
    if not self.observers[key] then self.observers[key] = {} end
    table.insert(self.observers[key], callback)
    return function() self:removeObserver(key, callback) end
end

function Settings:removeObserver(key, callback)
    for index, candidate in ipairs(self.observers[key] or {}) do
        if candidate == callback then table.remove(self.observers[key], index); return end
    end
end

function Settings:notifyObservers(key, value, previous)
    for _, callback in ipairs(self.observers[key] or {}) do callback(key, value, previous) end
    for _, callback in ipairs(self.observers["*"] or {}) do callback(key, value, previous) end
end

function Settings:isValidKey(key)
    return self.defaults[key] ~= nil
end

function Settings:isInitialized()
    return self.initialized
end

return Settings
