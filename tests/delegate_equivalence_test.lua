-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Equivalence test for init.lua's console-delegate consolidation.
--
-- init.lua used to spell out ~20 near-identical closures of the shape
--
--     function(arg)
--         if crosshair and crosshair.someMethod then
--             crosshair:someMethod(arg)
--         else
--             print("[HeadTracking:DIAG] crosshair driver not available")
--         end
--     end
--
-- and now builds them with a single `delegate(driver, method, opts)` helper.
-- The driver objects only exist inside the CET sandbox, so console_api_test
-- can only exercise the driver-is-nil half. This test covers the other half:
-- it holds the ORIGINAL inline closures side by side with a copy of the new
-- helper and asserts they agree - same printed output, same forwarded
-- argument, same receiver - across the full matrix of driver and argument
-- states, including the coercing and announcing variants.
--
-- If `delegate` in init.lua changes, update the copy below and re-run.

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("FAIL %s:\n  expected: %s\n  actual:   %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

--- Run fn with print captured; returns printed text.
local function capture(fn, ...)
    local real_print = print
    local lines = {}
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        lines[#lines + 1] = table.concat(parts, "\t")
    end
    local ok, err = pcall(fn, ...)
    _G.print = real_print
    if not ok then error("delegate threw: " .. tostring(err), 2) end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- The NEW implementation, copied verbatim from init.lua.
-- ---------------------------------------------------------------------------
local current_driver  -- stands in for init.lua's `crosshair` upvalue

local DRIVERS = {
    crosshair = { get = function() return current_driver end, label = "crosshair" },
}

local function toBool(v) return v and true or false end

local function delegate(driver_name, method, opts)
    opts = opts or {}
    local driver = DRIVERS[driver_name]
    return function(arg)
        local d = driver.get()
        if not (d and d[method]) then
            if not opts.silent then
                print("[HeadTracking:DIAG] " .. driver.label .. " driver not available")
            end
            return
        end
        local result
        if opts.noargs then
            result = d[method](d)
        else
            local value = arg
            if opts.coerce then value = opts.coerce(arg) end
            result = d[method](d, value)
        end
        if opts.announce then
            print("[HeadTracking:DIAG] " .. opts.announce .. tostring(result))
        end
    end
end

-- ---------------------------------------------------------------------------
-- The ORIGINAL inline closures, one per observed variant.
-- ---------------------------------------------------------------------------
local original = {
    -- plain forward
    probe = function(seconds)
        if current_driver and current_driver.probeNameplates then
            current_driver:probeNameplates(seconds)
        else
            print("[HeadTracking:DIAG] crosshair driver not available")
        end
    end,
    -- boolean-coercing forward
    hide = function(hidden)
        if current_driver and current_driver.setNameplatesHidden then
            current_driver:setNameplatesHidden(hidden and true or false)
        else
            print("[HeadTracking:DIAG] crosshair driver not available")
        end
    end,
    -- forward that announces the return value
    bracket = function(s)
        if current_driver and current_driver.setBracketScale then
            local v = current_driver:setBracketScale(s)
            print("[HeadTracking:DIAG] in-car bracket_scale = " .. tostring(v))
        else
            print("[HeadTracking:DIAG] crosshair driver not available")
        end
    end,
    -- silent variant (no else branch at all)
    reticle = function()
        if current_driver and current_driver.dumpStatus then
            current_driver:dumpStatus()
        end
    end,
}

local replacement = {
    probe   = delegate("crosshair", "probeNameplates"),
    hide    = delegate("crosshair", "setNameplatesHidden", { coerce = toBool }),
    bracket = delegate("crosshair", "setBracketScale",
                       { announce = "in-car bracket_scale = " }),
    reticle = delegate("crosshair", "dumpStatus", { silent = true, noargs = true }),
}

-- Method name backing each variant, so the fake driver can record calls.
local METHOD = {
    probe   = "probeNameplates",
    hide    = "setNameplatesHidden",
    bracket = "setBracketScale",
    reticle = "dumpStatus",
}

--- Driver that records the receiver and argument of the one method it has.
local function makeDriver(method, return_value)
    local d = { calls = {} }
    d[method] = function(self, arg)
        d.calls[#d.calls + 1] = { self_is_driver = (self == d), arg = arg }
        return return_value
    end
    return d
end

print("== console delegate equivalence ==")

local ARGS = { "<nil>", false, true, 0, 1.5, "text" }
local DRIVER_STATES = { "nil", "wrong-method", "present" }

local checks = 0
for variant, old_fn in pairs(original) do
    local new_fn = replacement[variant]
    local method = METHOD[variant]

    for _, driver_state in ipairs(DRIVER_STATES) do
        for _, raw_arg in ipairs(ARGS) do
            local arg = (raw_arg ~= "<nil>") and raw_arg or nil

            -- Build a fresh driver per side so call records stay separate.
            local function freshDriver()
                if driver_state == "nil" then return nil end
                if driver_state == "wrong-method" then
                    return makeDriver("someOtherMethod", nil)
                end
                return makeDriver(method, 0.75)
            end

            current_driver = freshDriver()
            local old_out = capture(old_fn, arg)
            local old_driver = current_driver

            current_driver = freshDriver()
            local new_out = capture(new_fn, arg)
            local new_driver = current_driver

            local label = string.format("%s(driver=%s, arg=%s)",
                variant, driver_state, tostring(arg))

            assert_eq(new_out, old_out, label .. " printed output")

            if driver_state == "present" then
                assert_eq(#new_driver.calls, #old_driver.calls, label .. " call count")
                local o, n = old_driver.calls[1], new_driver.calls[1]
                assert_eq(n.arg, o.arg, label .. " forwarded argument")
                assert_eq(n.self_is_driver, o.self_is_driver,
                          label .. " receiver is the driver (colon-call)")
            end
            checks = checks + 1
        end
    end
end

print(string.format("== Delegate equivalence OK: %d cases ==", checks))
