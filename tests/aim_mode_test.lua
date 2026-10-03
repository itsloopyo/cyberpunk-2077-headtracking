-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- The aim mode pair and the marker it switches on.

local AimMode = require("modules/aim_mode")
local AimMarker = require("modules/aim_marker")

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("FAIL %s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

-- The pair, read.
assert_eq(AimMode.decode(nil, nil), AimMode.SIGHTS_LOCKED, "both keys absent")
assert_eq(AimMode.decode(false, false), AimMode.SIGHTS_LOCKED, "both keys false")
assert_eq(AimMode.decode(true, nil), AimMode.TRUE_FREE_LOOK, "TrueFreeLook alone, the marker key absent")
assert_eq(AimMode.decode(true, false), AimMode.TRUE_FREE_LOOK, "TrueFreeLook alone")
assert_eq(AimMode.decode(false, true), AimMode.SIGHTS_LOCKED, "FreeLookMarker alone")
assert_eq(AimMode.decode(true, true), AimMode.FREE_LOOK_MARKER, "both keys true")

-- The pair, written, and the order the key steps through.
local mode = AimMode.SIGHTS_LOCKED
local walked = {}
for _ = 1, 4 do
    mode = AimMode.next(mode)
    walked[#walked + 1] = mode
    local free_look, marker = AimMode.encode(mode)
    assert_eq(AimMode.decode(free_look, marker), mode, "the pair round-trips " .. mode)
    assert(free_look or not marker, "the cycle never writes the marker without free look")
end
assert_eq(table.concat(walked, " "),
    "FreeLookMarker TrueFreeLook SightsLocked FreeLookMarker", "cycle order")
assert(not pcall(AimMode.next, "tracked"), "an unknown mode is an error")

assert_eq(AimMode.label(AimMode.SIGHTS_LOCKED), "Aim mode: sights locked", "label")
assert_eq(AimMode.label(AimMode.FREE_LOOK_MARKER), "Aim mode: free look with marker", "label")
assert_eq(AimMode.label(AimMode.TRUE_FREE_LOOK), "Aim mode: true free look", "label")

-- The marker is asked for in free look with a marker alone, and follows the
-- sights there.
for _, sights_up in ipairs({ 0.0, 0.3, 1.0 }) do
    assert_eq(AimMode.markerOpacity(AimMode.SIGHTS_LOCKED, sights_up), 0.0, "no marker in sights locked")
    assert_eq(AimMode.markerOpacity(AimMode.TRUE_FREE_LOOK, sights_up), 0.0, "no marker in true free look")
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
