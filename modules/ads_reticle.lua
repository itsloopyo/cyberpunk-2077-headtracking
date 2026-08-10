-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- ADS Reticle Module
-- Draws a custom ImGui crosshair at the true aim point while aiming down sights.
--
-- During ADS the game's aim stays decoupled (bullets land at the original
-- screen centre) while head tracking moves the view. The iron sights / scope
-- are not eye-levelled, so the player has no on-screen mark for where they are
-- actually aiming. This overlay projects the clean-aim direction into the
-- head-rotated view and draws a crosshair there.
--
-- This is an EXTRA reticle layered on top of builtin_crosshair (which drives
-- the engine's own widget); it only draws while is_ads is true.

local AdsReticle = {}
AdsReticle.__index = AdsReticle

local math_rad = math.rad
local math_deg = math.deg
local math_tan = math.tan
local math_atan = math.atan
local math_sin = math.sin
local math_cos = math.cos
local math_abs = math.abs
local math_max = math.max
local math_min = math.min

-- Cached ImGui window-flags bitfield. drawCrosshairAt() runs every render
-- frame; ImGuiWindowFlags is only populated after CET's onInit, so resolve
-- lazily on first draw. nil sentinel means "compute on next draw".
local _cached_window_flags = nil

local function _readCamFov(cam) return cam.fov end
-- cam.zoom field is stale (always 1.0); cam:GetZoom() is the live ADS
-- magnification. Effective FOV = base_fov / zoom (zoom narrows the FOV).
local function _readCamZoom(cam) return cam:GetZoom() end

--- @param settings table Settings module instance
--- @param camera table Camera module instance
--- @return table AdsReticle instance
function AdsReticle.new(settings, camera)
    if not settings then
        error("[HeadTracking] AdsReticle.new() requires a settings instance")
    end
    if not camera then
        error("[HeadTracking] AdsReticle.new() requires a camera instance")
    end

    local self = setmetatable({}, AdsReticle)
    self.settings = settings
    self.camera = camera

    self.style = {
        size = 12,
        thickness = 2,
        gap = 4,
        color = { r = 1.0, g = 1.0, b = 1.0, a = 0.8 },
        dot = true,
        dot_size = 2,
    }

    -- Fallback horizontal FOV (degrees), used only when GetFOV() fails.
    -- Shared with builtin_crosshair via crosshair_fov_degrees.
    self.fov_degrees = 84.0
    self.lead_factor = 0.0
    self.enabled = true

    self:refreshFromSettings()

    self._settings_unsubscribe = settings:observe("*", function(key)
        if key == "ads_reticle_enabled" or key == "ads_reticle_size" or
           key == "ads_reticle_opacity" or key == "crosshair_fov_degrees" or
           key == "crosshair_lead_factor" then
            self:refreshFromSettings()
        end
    end)

    return self
end

function AdsReticle:refreshFromSettings()
    local s = self.settings
    self.enabled = s:get("ads_reticle_enabled")
    self.fov_degrees = s:get("crosshair_fov_degrees") or 84.0
    self.lead_factor = s:get("crosshair_lead_factor") or 0.0
    self.style.size = s:get("ads_reticle_size") or 12
    self.style.color.a = s:get("ads_reticle_opacity") or 0.8
end

function AdsReticle:setEnabled(enabled)
    self.enabled = enabled and true or false
end

function AdsReticle:isEnabled() return self.enabled end

--- Draw the ADS reticle. Only draws while aiming down sights and enabled.
--- @param is_ads boolean Whether the player is aiming down sights (driven by
---        the iron-sight controller lifecycle; see modules/state.lua).
function AdsReticle:draw(is_ads)
    if not self.enabled or not is_ads then
        return
    end

    -- Decompose the rendered head pose (midpoint-averaged + optional lead,
    -- matching the engine's interpolated camera; see Camera:getRenderedYPR).
    local rot_yaw, rot_pitch, rot_roll = self.camera:getRenderedYPR(self.lead_factor)

    local screen_w, screen_h = GetDisplayResolution()
    if not screen_w or screen_w <= 0 then
        screen_w, screen_h = 1920, 1080
    end

    local center_x = screen_w * 0.5
    local center_y = screen_h * 0.5

    -- Live vertical FOV from entCameraComponent::fov * zoom. Falls back to the
    -- settings horizontal FOV if either is unreadable.
    local h_fov_deg
    local player = Game and Game.GetPlayer and Game.GetPlayer()
    local cam = player and player:GetFPPCameraComponent()
    local cam_fov, cam_zoom
    if cam then
        local ok, raw = pcall(_readCamFov, cam)
        if ok and type(raw) == "number" and raw > 0 then cam_fov = raw end
        local zok, zraw = pcall(_readCamZoom, cam)
        if zok and type(zraw) == "number" and zraw > 0 then cam_zoom = zraw end
    end
    local vfov = cam_fov and (cam_fov / (cam_zoom or 1.0)) or nil
    if vfov then
        local aspect = screen_w / screen_h
        local tan_half_v = math_tan(math_rad(vfov) * 0.5)
        h_fov_deg = math_deg(2.0 * math_atan(tan_half_v * aspect))
    else
        h_fov_deg = self.fov_degrees
    end
    local v_fov_deg = math_deg(2.0 * math_atan(
        math_tan(math_rad(h_fov_deg) * 0.5) * (screen_h / screen_w)))

    -- Spherical decomposition + perspective divide (FOV-correct, roll-aware).
    -- Mirrors cameraunlock-core ScreenOffsetCalculator.
    local yaw_rad = math_rad(rot_yaw)
    local pitch_rad = math_rad(rot_pitch)
    local roll_rad = math_rad(-(rot_roll or 0))

    local sy, cy_ = math_sin(yaw_rad), math_cos(yaw_rad)
    local sp, cp = math_sin(pitch_rad), math_cos(pitch_rad)

    local ax = sy
    local ay = sp * cy_
    local az = cp * cy_

    if math_abs(roll_rad) > 1e-4 then
        local cr, sr = math_cos(roll_rad), math_sin(roll_rad)
        local rx = ax * cr - ay * sr
        local ry = ax * sr + ay * cr
        ax, ay = rx, ry
    end

    local tan_half_h = math_tan(math_rad(h_fov_deg) * 0.5)
    local tan_half_v = math_tan(math_rad(v_fov_deg) * 0.5)

    local valid =
        math_abs(az) > 1e-3 and
        tan_half_h > 1e-3 and
        tan_half_v > 1e-3

    local cx, cy
    if valid then
        local offset_x = (ax / az) / tan_half_h * center_x
        local offset_y = (ay / az) / tan_half_v * center_y
        if offset_x == offset_x and offset_y == offset_y and
           math_abs(offset_x) < 1e6 and math_abs(offset_y) < 1e6 then
            cx = center_x + offset_x
            cy = center_y + offset_y
        end
    end

    if cx == nil then
        local last = self._last_good_draw
        if last then
            cx, cy = last.x, last.y
        else
            return
        end
    else
        self._last_good_draw = self._last_good_draw or {}
        self._last_good_draw.x = cx
        self._last_good_draw.y = cy
    end

    local margin = self.style.size + 10
    cx = math_max(margin, math_min(screen_w - margin, cx))
    cy = math_max(margin, math_min(screen_h - margin, cy))

    self:drawCrosshairAt(cx, cy)
end

--- @param x number Screen X position
--- @param y number Screen Y position
function AdsReticle:drawCrosshairAt(x, y)
    local style = self.style
    local c = style.color

    ImGui.SetNextWindowPos(0, 0)
    ImGui.SetNextWindowSize(GetDisplayResolution())

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

    local visible = ImGui.Begin("HeadTrackingAdsReticle", flags)
    if visible then
        local draw_list = ImGui.GetWindowDrawList()
        if draw_list then
            local color = ImGui.GetColorU32(c.r, c.g, c.b, c.a)

            ImGui.ImDrawListAddLine(draw_list,
                x - style.size - style.gap, y, x - style.gap, y,
                color, style.thickness)
            ImGui.ImDrawListAddLine(draw_list,
                x + style.gap, y, x + style.size + style.gap, y,
                color, style.thickness)
            ImGui.ImDrawListAddLine(draw_list,
                x, y - style.size - style.gap, x, y - style.gap,
                color, style.thickness)
            ImGui.ImDrawListAddLine(draw_list,
                x, y + style.gap, x, y + style.size + style.gap,
                color, style.thickness)

            if style.dot then
                ImGui.ImDrawListAddCircleFilled(draw_list,
                    x, y, style.dot_size, color, 12)
            end
        end
    end
    ImGui.End()

    ImGui.PopStyleVar(2)
end

return AdsReticle
