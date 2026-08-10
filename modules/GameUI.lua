--[[
GameUI Module - Game State Detection for Cyberpunk 2077
Vendored from cp2077-cet-kit (https://github.com/psiberx/cp2077-cet-kit)

This module provides game state detection for context-aware mod behavior.
It registers itself globally as 'GameUI' when required.

Original source: https://github.com/psiberx/cp2077-cet-kit/blob/main/mods/GameUI.lua
SPDX-License-Identifier: MIT
Copyright (c) 2021 Pavel Siberx
License: MIT (https://github.com/psiberx/cp2077-cet-kit/blob/main/LICENSE)

Features:
- Loading screen detection (IsLoading)
- Menu state detection (IsMenuOpen, GetCurrentMenu)
- Braindance detection (IsBraindance)
- Photo mode detection (IsPhoto)
- Scene/cinematic detection (IsScene)
- Vehicle state detection (IsVehicle, IsVehicleDriver)
- Event listener registration (Listen)
- Session start/end detection

Usage:
    require("modules/GameUI")
    if GameUI.IsLoading() then
        -- Handle loading state
    end
    GameUI.Listen("MenuOpen", function()
        -- Handle menu open event
    end)
--]]

local GameUI = {
    version = "1.0.0"
}

-- Internal state tracking
local state = {
    isLoaded = false,
    isLoading = false,
    isMenu = false,
    isScene = false,
    isBraindance = false,
    isPhoto = false,
    isVehicle = false,
    isDriver = false,
    isFastTravel = false,
    currentMenu = nil,
    listeners = {},
    initialized = false
}

-- Event types for listeners
local EVENT_TYPES = {
    "Init",
    "SessionStart",
    "SessionEnd",
    "LoadingStart",
    "LoadingFinish",
    "MenuOpen",
    "MenuClose",
    "MenuNav",
    "BraindanceStart",
    "BraindanceEnd",
    "PhotoModeOpen",
    "PhotoModeClose",
    "SceneStart",
    "SceneEnd",
    "VehicleEnter",
    "VehicleExit",
    "FastTravelStart",
    "FastTravelFinish"
}

-- =============================================================================
-- INTERNAL HELPER FUNCTIONS
-- =============================================================================

--- Safely call a callback function with error handling
--- @param callback function The callback to invoke
--- @param ... any Arguments to pass to callback
local function safeCall(callback, ...)
    if type(callback) ~= "function" then
        return
    end
    local ok, err = pcall(callback, ...)
    if not ok then
        print("[GameUI] Event callback error: " .. tostring(err))
    end
end

--- Fire an event to all registered listeners
--- @param event string Event name
--- @param ... any Additional event arguments
local function fireEvent(event, ...)
    local eventListeners = state.listeners[event]
    if eventListeners then
        for _, callback in ipairs(eventListeners) do
            safeCall(callback, ...)
        end
    end
end

--- Register a listener for an event
--- @param event string Event name
--- @param callback function Callback function
local function addListener(event, callback)
    if not state.listeners[event] then
        state.listeners[event] = {}
    end
    table.insert(state.listeners[event], callback)
end

--- Update menu state and fire events
--- @param isOpen boolean Whether menu is open
--- @param menuName string|nil Name of the menu
local function updateMenuState(isOpen, menuName)
    local wasOpen = state.isMenu
    local prevMenu = state.currentMenu

    state.isMenu = isOpen
    state.currentMenu = isOpen and menuName or nil

    if not wasOpen and isOpen then
        fireEvent("MenuOpen", menuName)
    elseif wasOpen and not isOpen then
        fireEvent("MenuClose", prevMenu)
    elseif wasOpen and isOpen and prevMenu ~= menuName then
        fireEvent("MenuNav", menuName, prevMenu)
    end
end

--- Update loading state and fire events
--- @param isLoading boolean Whether game is loading
local function updateLoadingState(isLoading)
    local wasLoading = state.isLoading
    state.isLoading = isLoading

    if not wasLoading and isLoading then
        fireEvent("LoadingStart")
    elseif wasLoading and not isLoading then
        fireEvent("LoadingFinish")
    end
end

--- Update braindance state and fire events
--- @param isBraindance boolean Whether in braindance
local function updateBraindanceState(isBraindance)
    local wasBraindance = state.isBraindance
    state.isBraindance = isBraindance

    if not wasBraindance and isBraindance then
        fireEvent("BraindanceStart")
    elseif wasBraindance and not isBraindance then
        fireEvent("BraindanceEnd")
    end
end

--- Update photo mode state and fire events
--- @param isPhoto boolean Whether photo mode is active
local function updatePhotoState(isPhoto)
    local wasPhoto = state.isPhoto
    state.isPhoto = isPhoto

    if not wasPhoto and isPhoto then
        fireEvent("PhotoModeOpen")
    elseif wasPhoto and not isPhoto then
        fireEvent("PhotoModeClose")
    end
end

--- Update scene state and fire events
--- @param isScene boolean Whether a scene/cinematic is playing
local function updateSceneState(isScene)
    local wasScene = state.isScene
    state.isScene = isScene

    if not wasScene and isScene then
        fireEvent("SceneStart")
    elseif wasScene and not isScene then
        fireEvent("SceneEnd")
    end
end

--- Update vehicle state and fire events
--- @param isVehicle boolean Whether player is in vehicle
--- @param isDriver boolean Whether player is driving
local function updateVehicleState(isVehicle, isDriver)
    local wasVehicle = state.isVehicle
    state.isVehicle = isVehicle
    state.isDriver = isDriver

    if not wasVehicle and isVehicle then
        fireEvent("VehicleEnter", isDriver)
    elseif wasVehicle and not isVehicle then
        fireEvent("VehicleExit")
    end
end

--- Update fast travel state and fire events
--- @param isFastTravel boolean Whether fast traveling
local function updateFastTravelState(isFastTravel)
    local wasFastTravel = state.isFastTravel
    state.isFastTravel = isFastTravel

    if not wasFastTravel and isFastTravel then
        fireEvent("FastTravelStart")
    elseif wasFastTravel and not isFastTravel then
        fireEvent("FastTravelFinish")
    end
end

-- =============================================================================
-- CET GAME OBSERVERS - Register for game state changes
-- =============================================================================

--- Initialize all game state observers
local function initializeObservers()
    if state.initialized then
        return
    end

    -- Observer registration must succeed wholesale. If any Observe call fails,
    -- state detection would silently turn into an always-on tracker - let it throw.
    do
        -- Menu state observers
        -- MenuScenario is the base class for all game menus
        Observe("MenuScenario", "OnEnter", function(self)
            local menuName = self:GetClassName():ToString()
            updateMenuState(true, menuName)
        end)

        Observe("MenuScenario", "OnLeave", function(self)
            updateMenuState(false, nil)
        end)

        -- Hub menu (inventory, map, journal, etc.)
        Observe("gameuiInGameMenuGameController", "OnInitialize", function()
            updateMenuState(true, "InGameMenu")
        end)

        Observe("gameuiInGameMenuGameController", "OnUninitialize", function()
            updateMenuState(false, nil)
        end)

        -- Pause menu
        Observe("PauseMenuGameController", "OnInitialize", function()
            updateMenuState(true, "PauseMenu")
        end)

        Observe("PauseMenuGameController", "OnUninitialize", function()
            updateMenuState(false, nil)
        end)

        -- Loading screen observers
        Observe("LoadingScreenProgressBarController", "OnInitialize", function()
            updateLoadingState(true)
        end)

        Observe("LoadingScreenProgressBarController", "OnUninitialize", function()
            updateLoadingState(false)
        end)

        -- Fast travel loading
        Observe("FastTravelSystem", "OnLoadingScreenFinished", function()
            updateLoadingState(false)
            updateFastTravelState(false)
        end)

        -- Braindance observers
        Observe("BraindanceGameController", "OnInitialize", function()
            updateBraindanceState(true)
        end)

        Observe("BraindanceGameController", "OnUninitialize", function()
            updateBraindanceState(false)
        end)

        -- Photo mode observers
        -- PhotoModeSystem.Activate is called with a boolean
        Observe("PhotoModeSystem", "Activate", function(self, isActive)
            updatePhotoState(isActive)
        end)

        -- Fallback: PhotoModePlayerEntityComponent
        Observe("PhotoModePlayerEntityComponent", "OnGameAttach", function()
            updatePhotoState(true)
        end)

        Observe("PhotoModePlayerEntityComponent", "OnGameDetach", function()
            updatePhotoState(false)
        end)

        -- Scene/cinematic observers
        -- SceneSystem handles all cutscenes and scenes
        ObserveAfter("SceneSystem", "SetSceneSystemEnterConditionOverwritten", function(self, value)
            updateSceneState(value)
        end)

        -- Alternate scene detection via dialog system
        Observe("DialogChoiceLogicController", "OnInitialize", function()
            -- Dialog is part of scene
        end)

        -- Vehicle state observers
        Observe("VehicleComponent", "OnVehicleFinishedMounting", function(self, mountingEvent)
            if mountingEvent then
                local isDriver = mountingEvent.character == Game.GetPlayer()
                updateVehicleState(true, isDriver)
            end
        end)

        Observe("VehicleComponent", "OnVehicleStartedUnmounting", function()
            updateVehicleState(false, false)
        end)

        -- Fast travel observers
        Observe("FastTravelSystem", "OnToggleFastTravelAvailabilityOnMapRequest", function()
            -- Fast travel initiated
        end)

        Observe("FastTravelSystem", "OnPerformFastTravel", function()
            updateFastTravelState(true)
            updateLoadingState(true)
        end)
    end

    state.initialized = true
end

-- =============================================================================
-- CET LIFECYCLE EVENTS
-- =============================================================================

registerForEvent("onInit", function()
    print("[GameUI] Initializing game state detection...")

    -- Initialize observers
    initializeObservers()

    state.isLoaded = true

    -- Fire init event for listeners registered before onInit
    fireEvent("Init")
    fireEvent("SessionStart")

    print("[GameUI] Game state detection ready")
end)

registerForEvent("onShutdown", function()
    state.isLoaded = false
    fireEvent("SessionEnd")
    state.listeners = {}
end)

-- =============================================================================
-- PUBLIC API - State Queries
-- =============================================================================

--- Check if game is currently loading
--- @return boolean True if loading screen is active
function GameUI.IsLoading()
    return state.isLoading
end

--- Check if any menu is currently open
--- @return boolean True if any menu is open
function GameUI.IsMenuOpen()
    return state.isMenu
end

--- Get the name of the currently open menu
--- @return string|nil Menu name or nil if no menu is open
function GameUI.GetCurrentMenu()
    return state.currentMenu
end

--- Check if player is in braindance
--- @return boolean True if braindance is active
function GameUI.IsBraindance()
    return state.isBraindance
end

--- Check if photo mode is active
--- @return boolean True if photo mode is active
function GameUI.IsPhoto()
    return state.isPhoto
end

--- Check if a scene or cinematic is playing
--- @return boolean True if scene is playing
function GameUI.IsScene()
    return state.isScene
end

--- Check if player is in a vehicle
--- @return boolean True if player is in a vehicle
function GameUI.IsVehicle()
    return state.isVehicle
end

--- Check if player is driving a vehicle
--- @return boolean True if player is the driver
function GameUI.IsVehicleDriver()
    return state.isDriver
end

--- Check if fast travel is in progress
--- @return boolean True if fast traveling
function GameUI.IsFastTravel()
    return state.isFastTravel
end

--- Check if game session is loaded (in gameplay)
--- @return boolean True if session is active
function GameUI.IsSessionLoaded()
    return state.isLoaded
end

--- Get all current state values
--- @return table State table with all current values
function GameUI.GetState()
    return {
        isLoaded = state.isLoaded,
        isLoading = state.isLoading,
        isMenu = state.isMenu,
        isScene = state.isScene,
        isBraindance = state.isBraindance,
        isPhoto = state.isPhoto,
        isVehicle = state.isVehicle,
        isDriver = state.isDriver,
        isFastTravel = state.isFastTravel,
        currentMenu = state.currentMenu
    }
end

-- =============================================================================
-- PUBLIC API - Event Listeners
-- =============================================================================

--- Register a callback for a game state event
--- @param event string Event name (see EVENT_TYPES for available events)
--- @param callback function Callback function to invoke when event fires
---
--- Available events:
---   Init - GameUI module initialized
---   SessionStart - Game session started (loaded into game)
---   SessionEnd - Game session ended (returned to main menu)
---   LoadingStart - Loading screen appeared
---   LoadingFinish - Loading screen finished
---   MenuOpen - Menu opened (passes menu name)
---   MenuClose - Menu closed (passes previous menu name)
---   MenuNav - Navigated between menus (passes new menu, old menu)
---   BraindanceStart - Entered braindance
---   BraindanceEnd - Exited braindance
---   PhotoModeOpen - Entered photo mode
---   PhotoModeClose - Exited photo mode
---   SceneStart - Cinematic/scene started
---   SceneEnd - Cinematic/scene ended
---   VehicleEnter - Entered vehicle (passes isDriver boolean)
---   VehicleExit - Exited vehicle
---   FastTravelStart - Fast travel initiated
---   FastTravelFinish - Fast travel completed
function GameUI.Listen(event, callback)
    if type(callback) ~= "function" then
        print("[GameUI] Warning: Listen callback must be a function")
        return
    end

    if type(event) ~= "string" then
        print("[GameUI] Warning: Event name must be a string")
        return
    end

    addListener(event, callback)
end

--- Remove all listeners for a specific event
--- @param event string Event name to clear
function GameUI.ClearListeners(event)
    if event then
        state.listeners[event] = nil
    end
end

--- Remove all listeners for all events
function GameUI.ClearAllListeners()
    state.listeners = {}
end

--- Get list of available event types
--- @return table Array of event type names
function GameUI.GetEventTypes()
    local copy = {}
    for _, v in ipairs(EVENT_TYPES) do
        table.insert(copy, v)
    end
    return copy
end

return GameUI
