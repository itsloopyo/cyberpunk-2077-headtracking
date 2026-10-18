-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- The aim mode settings, the stock sights share and the marker.

local AimMode = require("modules/aim_mode")
local AimMarker = require("modules/aim_marker")
local AdsFade = require("modules/ads_fade")

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("FAIL %s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

-- The settings, read.
assert_eq(AimMode.decode(nil, nil, nil), AimMode.SIGHTS_LOCKED, "all three keys absent")
assert_eq(AimMode.decode(false, false, false), AimMode.SIGHTS_LOCKED, "all three keys false")
assert_eq(AimMode.decode(nil, nil), AimMode.SIGHTS_LOCKED, "both keys absent")
assert_eq(AimMode.decode(false, false), AimMode.SIGHTS_LOCKED, "both keys false")
assert_eq(AimMode.decode(true, nil), AimMode.TRUE_FREE_LOOK, "TrueFreeLook alone, the marker key absent")
assert_eq(AimMode.decode(true, false), AimMode.TRUE_FREE_LOOK, "TrueFreeLook alone")
assert_eq(AimMode.decode(false, true), AimMode.SIGHTS_LOCKED, "FreeLookMarker alone")
assert_eq(AimMode.decode(true, true), AimMode.FREE_LOOK_MARKER, "both keys true")
assert_eq(AimMode.decode(true, false, false), AimMode.TRUE_FREE_LOOK, "a config from before stock sights")
for _, free_look in ipairs({ false, true }) do
    for _, marker in ipairs({ false, true }) do
        assert_eq(AimMode.decode(free_look, marker, true), AimMode.STOCK_SIGHTS,
            "StockSights wins over the other two")
    end
end

-- The settings, written, and the order the key steps through.
local mode = AimMode.SIGHTS_LOCKED
local walked = {}
for _ = 1, 5 do
    mode = AimMode.next(mode)
    walked[#walked + 1] = mode
    local free_look, marker, stock = AimMode.encode(mode)
    assert_eq(AimMode.decode(free_look, marker, stock), mode, "the settings round-trip " .. mode)
    assert(free_look or not marker, "the cycle never writes the marker without free look")
    assert(not (stock and (free_look or marker)), "stock sights is written with the other two false")
end
assert_eq(table.concat(walked, " "),
    "FreeLookMarker TrueFreeLook StockSights SightsLocked FreeLookMarker", "cycle order")
assert(not pcall(AimMode.next, "tracked"), "an unknown mode is an error")

assert_eq(AimMode.label(AimMode.SIGHTS_LOCKED), "Aim mode: sights locked", "label")
assert_eq(AimMode.label(AimMode.FREE_LOOK_MARKER), "Aim mode: free look with marker", "label")
assert_eq(AimMode.label(AimMode.TRUE_FREE_LOOK), "Aim mode: true free look", "label")
assert_eq(AimMode.label(AimMode.STOCK_SIGHTS), "Aim mode: stock sights", "label")

-- Stock sights hands the lean over as sights locked does, even beside a stray
-- TrueFreeLook.
assert_eq(AimMode.isFreeLook(AimMode.SIGHTS_LOCKED), false, "sights locked is not free look")
assert_eq(AimMode.isFreeLook(AimMode.FREE_LOOK_MARKER), true, "free look with a marker is free look")
assert_eq(AimMode.isFreeLook(AimMode.TRUE_FREE_LOOK), true, "true free look is free look")
assert_eq(AimMode.isFreeLook(AimMode.decode(true, false, true)), false,
    "stock sights with TrueFreeLook beside it is not free look")

-- The stock sights share, driven frame by frame as init.lua drives it.
local function near(actual, expected, label)
    if math.abs(actual - expected) > 1e-9 then
        error(string.format("FAIL %s: expected %.9f, got %.9f", label, expected, actual), 2)
    end
end
local YAW, PITCH, ROLL = 20.0, -8.0, 12.0
do
    local fade = AdsFade.new()
    local share = fade:update(AimMode.stockSightsEngaged(AimMode.STOCK_SIGHTS, false), 0.0)
    local y, p, r = AimMode.stockPose(share, YAW, PITCH, ROLL)
    near(y, YAW, "hip: yaw untouched")
    near(p, PITCH, "hip: pitch untouched")
    near(r, ROLL, "hip: roll untouched")

    fade:update(AimMode.stockSightsEngaged(AimMode.STOCK_SIGHTS, true), 1.0)
    share = fade:update(AimMode.stockSightsEngaged(AimMode.STOCK_SIGHTS, true), 1.0 + AdsFade.LOWER_S / 2)
    assert(share > 0.0 and share < 1.0, "half way down the share is between the ends")
    y, p, r = AimMode.stockPose(share, YAW, PITCH, ROLL)
    near(y, YAW * share, "mid: yaw scaled")
    near(p, PITCH * share, "mid: pitch scaled")
    near(r, ROLL, "mid: roll untouched")

    share = fade:update(AimMode.stockSightsEngaged(AimMode.STOCK_SIGHTS, true), 2.0)
    y, p, r = AimMode.stockPose(share, YAW, PITCH, ROLL)
    near(y, 0.0, "sights up: yaw gone")
    near(p, 0.0, "sights up: pitch gone")
    near(r, ROLL, "sights up: roll is the tracker's")
end

-- A reversal continues from where the share is, from the aim button and from
-- the mode key alike.
for _, reversal in ipairs({ "aim button", "mode key" }) do
    local fade = AdsFade.new()
    fade:update(AimMode.stockSightsEngaged(AimMode.STOCK_SIGHTS, false), 0.0)
    fade:update(AimMode.stockSightsEngaged(AimMode.STOCK_SIGHTS, true), 1.0)
    local t = 1.0 + AdsFade.LOWER_S / 3
    local before = fade:update(AimMode.stockSightsEngaged(AimMode.STOCK_SIGHTS, true), t)
    local engaged
    if reversal == "aim button" then
        engaged = AimMode.stockSightsEngaged(AimMode.STOCK_SIGHTS, false)
    else
        engaged = AimMode.stockSightsEngaged(AimMode.SIGHTS_LOCKED, true)
    end
    near(fade:update(engaged, t), before, "a reversal by the " .. reversal .. " does not step")
    local later = fade:update(engaged, t + 0.01)
    assert(later > before and later < 1.0, "and heads back to the hip from there")
end

-- In the other three modes the share stays 1, sights up or down.
for _, other in ipairs({ AimMode.SIGHTS_LOCKED, AimMode.FREE_LOOK_MARKER, AimMode.TRUE_FREE_LOOK }) do
    local fade = AdsFade.new()
    for frame = 0, 60 do
        near(fade:update(AimMode.stockSightsEngaged(other, frame % 20 < 12), frame / 60), 1.0,
            other .. ": the stock sights share is whole")
    end
end

-- The marker is asked for in free look with a marker alone, and follows the
-- sights there.
for _, sights_up in ipairs({ 0.0, 0.3, 1.0 }) do
    assert_eq(AimMode.markerOpacity(AimMode.SIGHTS_LOCKED, sights_up), 0.0, "no marker in sights locked")
    assert_eq(AimMode.markerOpacity(AimMode.TRUE_FREE_LOOK, sights_up), 0.0, "no marker in true free look")
    assert_eq(AimMode.markerOpacity(AimMode.STOCK_SIGHTS, sights_up), 0.0, "no marker in stock sights")
    assert_eq(AimMode.markerOpacity(AimMode.FREE_LOOK_MARKER, sights_up), sights_up, "the marker follows the sights")
end

-- The drawing: nothing at zero opacity or without a valid aim point, and at the
-- projected aim point otherwise.
local lines, began = {}, 0
local offset = { dx = 120, dy = -40, valid = true }
local crosshair = { getAimOffset = function() return offset.dx, offset.dy, offset.valid end }
GetDisplayResolution = function() return 1920, 1080 end
ImGuiWindowFlags = setmetatable({}, { __index = function() return 0 end })
ImGuiStyleVar = setmetatable({}, { __index = function() return 0 end })
ImGui = {
    SetNextWindowPos = function() end,
    SetNextWindowSize = function() end,
    PushStyleVar = function() end,
    PopStyleVar = function() end,
    Begin = function() began = began + 1; return true end,
    End = function() end,
    GetWindowDrawList = function() return {} end,
    GetColorU32 = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end,
    ImDrawListAddLine = function(_, x1, y1, x2, y2, color)
        lines[#lines + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, color = color }
    end,
}
local marker = AimMarker.new(crosshair)

assert_eq(marker:draw(0.0), false, "zero opacity draws nothing")
assert_eq(began, 0, "and opens no window")

offset.valid = false
assert_eq(marker:draw(1.0), false, "an aim point behind the view draws nothing")
assert_eq(#lines, 0, "not even at the last position")

offset.valid = true
assert_eq(marker:draw(0.5), true, "sights up in free look with a marker draws")
assert_eq(#lines, 8, "an outline cross and an ink cross")
local cx, cy = 1920 / 2 + 120, 1080 / 2 - 40
for _, line in ipairs(lines) do
    assert(math.abs((line.x1 + line.x2) / 2 - cx) <= AimMarker.ARM_PIXELS + 1
        and math.abs((line.y1 + line.y2) / 2 - cy) <= AimMarker.ARM_PIXELS + 1,
        "every arm sits on the projected aim point")
end
assert_eq(lines[1].color.r, 0, "the outline is drawn first, dark")
assert_eq(lines[5].color.r, 1, "the ink is white")
assert(math.abs(lines[5].color.a - 0.5 * 0xE6 / 255) < 1e-12, "and its opacity follows the fade")

lines = {}
offset.dx = 5000
assert_eq(marker:draw(1.0), false, "an aim point off the screen draws nothing")

print("== Aim mode OK ==")
