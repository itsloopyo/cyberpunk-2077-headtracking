-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Aim marker
-- The small white cross of free look with a marker, drawn where the round will
-- land while the sights are up. In that mode the weapon stays put in the world
-- and the head moves around it, so the sights only say where the round goes
-- with the head behind them. This mark says it from anywhere.
--
-- The position is not worked out here. builtin_crosshair projects the clean aim
-- through the tracked view to place the game's own crosshair at the hip, and
-- this draws at that same offset.
--
-- The style is cameraunlock-core's AimMarkerStyle (rendering/aim_marker.h),
-- which CET cannot load; tests/core_constants_test.lua pins the numbers to it.

local AimMarker = {}
AimMarker.__index = AimMarker

local ARM_PIXELS = 9
local GAP_PIXELS = 3
local THICKNESS_PIXELS = 2
local INK_ALPHA = 0xE6 / 255
local OUTLINE_ALPHA = 0x99 / 255
-- The outline is the same cross drawn wider and longer behind the ink.
local OUTLINE_GROW = 1

AimMarker.ARM_PIXELS = ARM_PIXELS
AimMarker.GAP_PIXELS = GAP_PIXELS
AimMarker.THICKNESS_PIXELS = THICKNESS_PIXELS

-- ImGuiWindowFlags is only populated after CET's onInit.
local window_flags = nil

--- @param crosshair table builtin_crosshair instance, the projection source
function AimMarker.new(crosshair)
    assert(crosshair, "AimMarker needs the crosshair driver for its projection")
    return setmetatable({ crosshair = crosshair }, AimMarker)
end

local function cross(dl, x, y, arm, gap, color, thickness)
    ImGui.ImDrawListAddLine(dl, x - arm, y, x - gap, y, color, thickness)
    ImGui.ImDrawListAddLine(dl, x + gap, y, x + arm, y, color, thickness)
    ImGui.ImDrawListAddLine(dl, x, y - arm, x, y - gap, color, thickness)
    ImGui.ImDrawListAddLine(dl, x, y + gap, x, y + arm, color, thickness)
end

--- @param opacity number 0 draws nothing, 1 is the full mark
--- @return boolean drawn
function AimMarker:draw(opacity)
    if opacity <= 0 then return false end

    local dx, dy, valid = self.crosshair:getAimOffset()
    -- Behind the view, or unreadable: a mark left at its last place would point
    -- somewhere the rounds are not going.
    if not valid then return false end
    local screen_w, screen_h = GetDisplayResolution()
    local x, y = screen_w * 0.5 + dx, screen_h * 0.5 + dy
    if x < 0 or x > screen_w or y < 0 or y > screen_h then return false end

    if not window_flags then
        window_flags = ImGuiWindowFlags.NoTitleBar
            + ImGuiWindowFlags.NoResize
            + ImGuiWindowFlags.NoMove
            + ImGuiWindowFlags.NoInputs
            + ImGuiWindowFlags.NoSavedSettings
            + ImGuiWindowFlags.NoFocusOnAppearing
            + ImGuiWindowFlags.NoBringToFrontOnFocus
            + ImGuiWindowFlags.NoBackground
    end

    ImGui.SetNextWindowPos(0, 0)
    ImGui.SetNextWindowSize(screen_w, screen_h)
    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 0, 0)
    ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0)
    if ImGui.Begin("HeadTrackingAimMarker", window_flags) then
        local dl = ImGui.GetWindowDrawList()
        cross(dl, x, y, ARM_PIXELS + OUTLINE_GROW, GAP_PIXELS - OUTLINE_GROW,
            ImGui.GetColorU32(0, 0, 0, OUTLINE_ALPHA * opacity), THICKNESS_PIXELS + 2 * OUTLINE_GROW)
        cross(dl, x, y, ARM_PIXELS, GAP_PIXELS,
            ImGui.GetColorU32(1, 1, 1, INK_ALPHA * opacity), THICKNESS_PIXELS)
    end
    ImGui.End()
    ImGui.PopStyleVar(2)
    return true
end

return AimMarker
