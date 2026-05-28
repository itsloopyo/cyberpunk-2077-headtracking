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
assert_true(s:set("smoothing_factor", 0.5), "smoothing_factor 0.5 accepted")
assert_true(s:set("smoothing_factor", 2.0), "smoothing_factor 2.0 clamps")
assert_eq(s:get("smoothing_factor"), 0.99, "smoothing_factor clamped to max=0.99")

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

print("== All settings tests passed ==")

-- best-effort cleanup
os.remove("config.json")
os.remove("config.json.bak")
