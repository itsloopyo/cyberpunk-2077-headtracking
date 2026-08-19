-- Settings module self-test. Runnable under stock lua5.4 (no CET sandbox)
-- so it can be wired into CI alongside the existing syntax check.
--
-- Covers the boundary fixes added in the security/bug audit:
--   1. yaw_mode :set() rejects values outside the {"world","local"} enum.
--   2. NaN, out-of-range and wrong-type numbers are rejected/clamped, not
--      silently accepted.
--   3. save() crash-recovery: a save that succeeds leaves no .bak orphan
--      from the previous successful save (older one rolled forward), and
--      the file ends up with the encoded payload.
--
-- Lua-only - uses a stub `json` global and a temporary working directory
-- so it does not touch a real CET install.

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("FAIL %s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

local function assert_true(v, label)
    if not v then error("FAIL " .. label .. ": expected truthy, got " .. tostring(v), 2) end
end

local function assert_false(v, label)
    if v then error("FAIL " .. label .. ": expected falsy, got " .. tostring(v), 2) end
end

-- Minimal JSON stub (encode-only is all settings.save needs in this test;
-- decode is exercised via load() below). Encodes booleans, numbers, strings,
-- and tables-as-objects. Good enough to round-trip the settings table.
local function json_encode(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then return tostring(v) end
    if t == "string" then return '"' .. v:gsub('"', '\\"') .. '"' end
    if t == "table" then
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts+1] = '"' .. tostring(k) .. '":' .. json_encode(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("json_encode: unsupported type " .. t)
end

local function json_decode(s)
    -- Trivial decode for our save format - just round-trips the encode above.
    -- For test purposes we only need the failure path; load() falls back to
    -- defaults when decode fails.
    if not s or s == "" then return nil end
    -- Build a tiny parser that handles flat objects of literal values.
    local out = {}
    for k, v in s:gmatch('"([^"]+)":([^,}]+)') do
        if v == "true" then
            out[k] = true
        elseif v == "false" then
            out[k] = false
        elseif v:match('^"') then
            out[k] = v:sub(2, -2)
        else
            local n = tonumber(v)
            if n then out[k] = n end
        end
    end
    return out
end

_G.json = { encode = json_encode, decode = json_decode }

-- Cross-platform temp dir: lua's os.tmpname returns a leaked file path; we
-- only need its parent directory for cwd. A subdir is safer than mutating
-- pwd globally.
local function make_tmpdir()
    local sep = package.config:sub(1, 1)
    local base = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
    local dir = base .. sep .. "headtracking-settings-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(1, 999999))
    -- Best-effort mkdir; works on POSIX and cmd.exe.
    if sep == "\\" then
        os.execute('mkdir "' .. dir .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. dir .. '"')
    end
    return dir
end

local tmpdir = make_tmpdir()

-- Make modules/settings.lua importable. Test runner can be invoked from
-- repo root as `lua tests/settings_test.lua`.
package.path = "./?.lua;./modules/?.lua;" .. package.path
local Settings = require("modules.settings")
if not Settings then Settings = require("settings") end

-- Run the test inside the temp dir so config.json writes don't pollute repo.
local original_open = io.open
local function rebase_open(path, mode)
    if not path:match("[/\\]") and not path:match("^%a:") then
        local sep = package.config:sub(1, 1)
        path = tmpdir .. sep .. path
    end
    return original_open(path, mode)
end
io.open = rebase_open

local original_remove = os.remove
local original_rename = os.rename
os.remove = function(p)
    if not p:match("[/\\]") and not p:match("^%a:") then
        local sep = package.config:sub(1, 1)
        p = tmpdir .. sep .. p
    end
    return original_remove(p)
end
os.rename = function(a, b)
    local sep = package.config:sub(1, 1)
    if not a:match("[/\\]") and not a:match("^%a:") then a = tmpdir .. sep .. a end
    if not b:match("[/\\]") and not b:match("^%a:") then b = tmpdir .. sep .. b end
    return original_rename(a, b)
end

print("== Settings validation tests ==")

local s = Settings.new()
s:load()

-- (1) yaw_mode enum
assert_true(s:set("yaw_mode", "world"), "yaw_mode='world' accepted")
assert_eq(s:get("yaw_mode"), "world", "yaw_mode stored as 'world'")
assert_true(s:set("yaw_mode", "local"), "yaw_mode='local' accepted")
assert_eq(s:get("yaw_mode"), "local", "yaw_mode stored as 'local'")
assert_false(s:set("yaw_mode", "world_simple"), "yaw_mode='world_simple' rejected")
assert_eq(s:get("yaw_mode"), "local", "yaw_mode unchanged after rejection")
assert_false(s:set("yaw_mode", ""), "empty yaw_mode rejected")
assert_eq(s:get("yaw_mode"), "local", "yaw_mode unchanged after empty rejection")

-- (2) numeric validation
assert_true(s:set("sensitivity_yaw", 1.5), "sensitivity_yaw 1.5 accepted")
assert_eq(s:get("sensitivity_yaw"), 1.5, "sensitivity_yaw stored")
-- Out-of-range clamps and reports clamped value.
assert_true(s:set("sensitivity_yaw", 99), "sensitivity_yaw 99 clamps")
assert_eq(s:get("sensitivity_yaw"), 5.0, "sensitivity_yaw clamped to max=5.0")
-- Wrong type rejected outright.
assert_false(s:set("sensitivity_yaw", "lots"), "sensitivity_yaw string rejected")
-- NaN rejected.
local nan = 0/0
assert_false(s:set("sensitivity_yaw", nan), "sensitivity_yaw NaN rejected")
-- Smoothing factor is bounded.
assert_true(s:set("local_smoothing", 0.5), "local_smoothing 0.5 accepted")
assert_true(s:set("local_smoothing", 2.0), "local_smoothing 2.0 clamps")
assert_eq(s:get("local_smoothing"), 1.0, "local_smoothing clamped to max=1.0")
assert_true(s:set("local_smoothing", 0.0), "local_smoothing 0.0 accepted (no floor)")
assert_eq(s:get("local_smoothing"), 0.0, "local_smoothing 0.0 survives, never floored")
assert_true(s:set("remote_smoothing", 0.15), "remote_smoothing 0.15 accepted")
assert_eq(s:get("remote_smoothing"), 0.15, "remote_smoothing round-trips")

-- (2b) retired smoothing keys warn once and migrate nothing.
-- A separate instance on its own path so this does not disturb the config.json
-- the .bak rotation checks below depend on.
do
    local printed = {}
    local real_print = print
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        printed[#printed + 1] = table.concat(parts, " ")
    end

    local retired_path = "retired_config.json"

    -- Guard order: a config with no retired key must not consume the one-shot.
    local cf = io.open(retired_path, "w")
    cf:write('{"sensitivity_yaw":1.0}')
    cf:close()
    local s_clean = Settings.new()
    s_clean.path = retired_path
    s_clean:load()
    local clean_warnings = 0
    for _, line in ipairs(printed) do
        if line:match("has been retired") or line:match("have been retired") then
            clean_warnings = clean_warnings + 1
        end
    end
    assert_eq(clean_warnings, 0, "no warning when no retired key is present")
    printed = {}

    -- Both retired keys present, with values a user would have tuned.
    local rf = io.open(retired_path, "w")
    rf:write('{"smoothing_factor":0.5,"position_smoothing":0.75,"sensitivity_yaw":1.0}')
    rf:close()

    local s_retired = Settings.new()
    s_retired.path = retired_path
    s_retired:load()

    local warning = nil
    for _, line in ipairs(printed) do
        if line:match("retired") then warning = line end
    end
    _G.print = real_print

    assert_true(warning, "retired smoothing keys produce a warning")
    -- Both retired spellings and both replacements have to be named, or the
    -- message does not tell the user what to edit.
    assert_true(warning:match("'smoothing_factor'"), "warning names smoothing_factor")
    assert_true(warning:match("'position_smoothing'"), "warning names position_smoothing")
    assert_true(warning:match("IGNORED"), "warning says the key is ignored")
    assert_true(warning:match("'local_smoothing'"), "warning names local_smoothing")
    assert_true(warning:match("'remote_smoothing'"), "warning names remote_smoothing")
    assert_true(warning:match("not migrated"), "warning says the value is not migrated")
    assert_true(warning:match("0%.15"), "warning names the retired hidden floor")

    -- Nothing carried over: 0.5 and 0.75 are gone, both new keys are defaults.
    assert_eq(s_retired:get("local_smoothing"), 0.0, "local_smoothing kept its default")
    assert_eq(s_retired:get("remote_smoothing"), 0.15, "remote_smoothing kept its default")

    -- Once only. The settings are re-read whenever the mod hot-reloads.
    printed = {}
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        printed[#printed + 1] = table.concat(parts, " ")
    end
    local s_again = Settings.new()
    s_again.path = retired_path
    s_again:load()
    _G.print = real_print
    for _, line in ipairs(printed) do
        assert_false(line:match("retired"), "second load repeats no retired-key warning")
    end

    os.remove(retired_path)
end

-- (3) save crash-recovery rotation: after a successful save against an
-- existing config the previous file is preserved as .bak. Settings:set
-- already auto-saves, so two distinct sets give us "old in .bak, new in
-- main" without explicit :save() calls.
assert_true(s:set("clamp_yaw", 100), "clamp_yaw 100 accepted")
assert_true(s:set("clamp_yaw", 110), "clamp_yaw 110 accepted")

local sep = package.config:sub(1, 1)
local cfg_path = tmpdir .. sep .. "config.json"
local bak_path = tmpdir .. sep .. "config.json.bak"
local f = original_open(cfg_path, "r")
assert_true(f, "config.json present after save")
local body = f:read("*all"); f:close()
assert_true(body:match('"clamp_yaw":110'), "config.json contains latest clamp_yaw=110")

local fb = original_open(bak_path, "r")
assert_true(fb, "config.json.bak written from previous save")
local bbody = fb:read("*all"); fb:close()
assert_true(bbody:match('"clamp_yaw":100'), "config.json.bak retains previous clamp_yaw=100")

-- (4) save preserves yaw_mode normalization across reload.
local s2 = Settings.new()
local loaded_from_file = s2:load()
assert_true(loaded_from_file, "second instance loaded existing config")
assert_eq(s2:get("yaw_mode"), "local", "loaded yaw_mode unchanged")

-- (5) every default has a validation rule. A key present in defaults but
-- missing from VALIDATION_RULES type-checks as invalid, so :set() refuses it
-- and :load() throws the user's saved value away on every launch - which is
-- exactly what happened to freeze_frame_enabled.
for key, default_value in pairs(s:getDefaults()) do
    assert_true(s:getValidationRules(key),
        "default '" .. key .. "' has a validation rule")
    assert_true(s:set(key, default_value),
        "default value for '" .. key .. "' is accepted by :set()")
end

-- (6) freeze_frame_enabled specifically: settable, and survives a reload.
assert_true(s:set("freeze_frame_enabled", true), "freeze_frame_enabled=true accepted")
assert_eq(s:get("freeze_frame_enabled"), true, "freeze_frame_enabled stored as true")
local s3 = Settings.new()
s3:load()
assert_eq(s3:get("freeze_frame_enabled"), true, "freeze_frame_enabled survives reload")
assert_true(s:set("freeze_frame_enabled", false), "freeze_frame_enabled=false accepted")
assert_false(s:set("freeze_frame_enabled", "yes"), "freeze_frame_enabled string rejected")

print("== All settings tests passed ==")

-- best-effort cleanup
os.remove("config.json")
os.remove("config.json.bak")
