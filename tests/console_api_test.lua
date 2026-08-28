-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Characterization test for init.lua's console API (the returned mod table).
--
-- CET sandboxes each mod's globals, so the table returned from init.lua is the
-- ONLY way the user reaches these from the console:
--   GetMod("HeadTracking").DiagCleanCam(true)
--
-- That makes the table a public API. This test pins its exact shape and the
-- exact message every entry emits while its driver is nil, so a refactor of
-- the dispatch cannot silently drop an entry, rename one, or change what the
-- user sees.
--
-- init.lua is loaded with a stub sandbox. registerForEvent is captured rather
-- than invoked, so onInit never runs and the module locals (crosshair, camera,
-- aim, settings, ui) stay nil by construction - the driver-missing branch is
-- therefore deterministic regardless of which modules compile under stock Lua.

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("FAIL %s:\n  expected: %s\n  actual:   %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

-- Expected console entries and the exact output each produces when its
-- backing driver has not been initialised. `false` means "prints nothing";
-- ANY_OUTPUT means "must exist and not throw, but the text is not pinned".
local ANY_OUTPUT = setmetatable({}, { __tostring = function() return "<any>" end })
local CROSSHAIR_MISSING = "[HeadTracking:DIAG] crosshair driver not available"
local CAMERA_MISSING    = "[HeadTracking:DIAG] camera driver not available"
local AIM_MISSING       = "[HeadTracking:DIAG] aim driver not available"

local EXPECTED = {
    DiagBracketScale      = CROSSHAIR_MISSING,
    DiagCrosshairMotion   = CROSSHAIR_MISSING,
    DiagCrosshairSuppress = CROSSHAIR_MISSING,
    DiagCrosshairTree     = CROSSHAIR_MISSING,
    DiagGate              = CROSSHAIR_MISSING,
    DiagSmartProbe        = CROSSHAIR_MISSING,
    DiagSmartScale        = CROSSHAIR_MISSING,
    DiagSmartTargets      = CROSSHAIR_MISSING,
    DiagHitMarker         = CROSSHAIR_MISSING,
    DiagLockSignal        = CROSSHAIR_MISSING,
    DiagNameplateAnchor   = CROSSHAIR_MISSING,
    DiagNameplateHide     = CROSSHAIR_MISSING,
    DiagNameplateProbe    = CROSSHAIR_MISSING,
    DiagShoveHitMarker    = CROSSHAIR_MISSING,
    DiagShoveNameplate    = CROSSHAIR_MISSING,
    DiagShoveOnly         = CROSSHAIR_MISSING,
    DiagYawBasis          = CAMERA_MISSING,
    DiagYawMode           = CAMERA_MISSING,
    DiagShotDiscovery     = AIM_MISSING,
    DiagCleanCam          = "[HeadTracking:DIAG] settings/ui not initialised; mod still booting?",

    -- These two intentionally stay SILENT when the crosshair driver is
    -- absent, unlike the 14 above. Pinned so the asymmetry is a deliberate,
    -- visible choice rather than something a refactor quietly "tidies up".
    DiagReticle           = false,
    DiagDumpTrees         = false,

    -- DebugLog is a plain module-level require with no CET dependency, so
    -- whether it loads is environment-dependent. Only require that the entry
    -- exists and is callable, not what it prints.
    DiagVerbose           = ANY_OUTPUT,
}

print("== init.lua console API characterization ==")

local registered = {}
_G.registerForEvent = function(name, fn) registered[name] = fn end
_G.Game = { GetPlayer = function() return nil end }

local mod = dofile("init.lua")
assert_eq(type(mod), "table", "init.lua returns a table")

-- Every lifecycle event the CET host expects must still be registered.
for _, evt in ipairs({ "onInit", "onUpdate", "onDraw", "onShutdown" }) do
    assert_eq(type(registered[evt]), "function", "registerForEvent(" .. evt .. ")")
end

--- Call fn with `print` captured, returning everything it printed.
local function captureOutput(fn, ...)
    local real_print = print
    local lines = {}
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        lines[#lines + 1] = table.concat(parts, "\t")
    end
    local ok, err = pcall(fn, ...)
    _G.print = real_print
    return ok, err, table.concat(lines, "\n")
end

-- No entry may disappear, and no unexpected entry may appear.
for name in pairs(EXPECTED) do
    assert_eq(type(mod[name]), "function", "mod." .. name .. " is a function")
end
for name in pairs(mod) do
    if EXPECTED[name] == nil then
        error("FAIL unexpected console entry '" .. name ..
              "' - add it to EXPECTED (it is public API)", 0)
    end
end

-- Each entry must be callable with no driver present, must not throw, and
-- must emit exactly the pinned message.
local checked = 0
for name, expected_output in pairs(EXPECTED) do
    local ok, err, output = captureOutput(mod[name])
    assert_eq(ok, true, name .. " must not throw when its driver is nil"
                        .. (ok and "" or (": " .. tostring(err))))
    if expected_output == false then
        assert_eq(output, "", name .. " stays silent when driver is nil")
    elseif expected_output ~= ANY_OUTPUT then
        assert_eq(output, expected_output, name .. " driver-missing message")
    end
    checked = checked + 1
end

print(string.format("== Console API OK: %d entries pinned ==", checked))
