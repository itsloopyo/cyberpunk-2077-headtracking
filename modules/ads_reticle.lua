-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- ADS Aim Marker
-- Draws an ImGui crosshair at the true aim point while aiming down sights.
--
-- Only ads_mode = "marker" uses this. In that mode head tracking keeps running
-- through the aim, so the view drifts off the weapon's sight line while the
-- rounds keep going where the sights point. The game hides its own hip-fire
-- crosshair during ADS and the iron sights are not eye-levelled, which leaves
-- the player no on-screen mark for where they are actually aiming. This is that
-- mark.
--
-- The projection is NOT recomputed here. builtin_crosshair owns the one
-- projection in this mod - it is 6DOF-aware, roll-aware, and reads the live
-- ADS zoom - and a second copy of that math would agree at small single-axis
-- angles and drift apart on combined poses, which is the failure AGENTS.md
-- calls out. This module asks for that offset and draws at it.

local AdsReticle = {}
AdsReticle.__index = AdsReticle

local math_max = math.max
local math_min = math.min

-- Fixed style. The mode itself is the on/off switch, so there is nothing here
-- worth a settings entry until someone asks for one.
local SIZE = 12
local THICKNESS = 2
local GAP = 4
local DOT_RADIUS = 2
local COLOR = { r = 1.0, g = 1.0, b = 1.0, a = 0.8 }

-- ImGuiWindowFlags is only populated after CET's onInit, so the bitfield is
-- resolved on first draw rather than at require time.
local _cached_window_flags = nil

--- @param crosshair table builtin_crosshair instance, the projection source
--- @return table AdsReticle instance
function AdsReticle.new(crosshair)
    if not crosshair then
        error("[HeadTracking] AdsReticle.new() requires a crosshair instance")
    end
    local self = setmetatable({}, AdsReticle)
    self.crosshair = crosshair
    return self
end

--- Draw the marker. A no-op unless `active`, which init.lua sets only while the
--- sights are up in ads_mode = "marker".
--- @param active boolean
function AdsReticle:draw(active)
    if not active then return end

    local screen_w, screen_h = GetDisplayResolution()
    if not screen_w or screen_w <= 0 then
        screen_w, screen_h = 1920, 1080
    end

    local dx, dy, valid = self.crosshair:getAimOffset(screen_w, screen_h)
    if not valid then
        -- Behind the tracked view or an unreadable FOV. Drawing the last known
        -- position would park a marker somewhere the rounds are not going, so
        -- draw nothing at all.
        return
    end

    local margin = SIZE + GAP + 2
    local x = math_max(margin, math_min(screen_w - margin, screen_w * 0.5 + dx))
    local y = math_max(margin, math_min(screen_h - margin, screen_h * 0.5 + dy))

    ImGui.SetNextWindowPos(0, 0)
    ImGui.SetNextWindowSize(screen_w, screen_h)

    local flags = _cached_window_flags
    if not flags then
        flags = ImGuiWindowFlags.NoTitleBar
              + ImGuiWindowFlags.NoResize
              + ImGuiWindowFlags.NoMove
              + ImGuiWindowFlags.NoInputs
              + ImGuiWindowFlags.NoSavedSettings
              + ImGuiWindowFlags.NoFocusOnAppearing
              + ImGuiWindowFlags.NoBringToFrontOnFocus
              + ImGuiWindowFlags.NoBackground
        _cached_window_flags = flags
    end

    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 0, 0)
    ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0)

    if ImGui.Begin("HeadTrackingAdsReticle", flags) then
        local dl = ImGui.GetWindowDrawList()
        if dl then
            local color = ImGui.GetColorU32(COLOR.r, COLOR.g, COLOR.b, COLOR.a)
            ImGui.ImDrawListAddLine(dl, x - SIZE - GAP, y, x - GAP, y, color, THICKNESS)
            ImGui.ImDrawListAddLine(dl, x + GAP, y, x + SIZE + GAP, y, color, THICKNESS)
            ImGui.ImDrawListAddLine(dl, x, y - SIZE - GAP, x, y - GAP, color, THICKNESS)
            ImGui.ImDrawListAddLine(dl, x, y + GAP, x, y + SIZE + GAP, color, THICKNESS)
            ImGui.ImDrawListAddCircleFilled(dl, x, y, DOT_RADIUS, color, 12)
        end
    end
    ImGui.End()

    ImGui.PopStyleVar(2)
end

return AdsReticle
