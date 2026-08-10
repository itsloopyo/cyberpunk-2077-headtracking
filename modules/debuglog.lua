-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Debug Log Module
-- Mirrors diagnostic lines to both the CET console AND a file in the mod
-- folder so long-lived diag state stays readable after the CET console
-- scrolls past. File path is relative (CET's Lua working dir is the mod
-- folder), so it lands at:
--   <game>/bin/x64/plugins/cyber_engine_tweaks/mods/HeadTracking/HeadTracking.log
--
-- Usage (optional all over the codebase):
--   local DebugLog = require("modules/debuglog")
--   DebugLog.init()          -- once at onInit; truncates prior log
--   DebugLog.write("...")    -- one-shot: prints + appends timestamped line
--
-- Keep callers on rate-limited paths (per-frame print is fine for the
-- console but would create a fsync-heavy log).

local DebugLog = {}

-- Use a separate filename from the one CET uses for its per-mod error log
-- (CET writes script load errors and the like to HeadTracking.log). Our
-- file is for mod-internal diagnostics only.
local LOG_PATH = "HeadTracking-diag.log"
local initialized = false

-- Master mute. When false (the default) DebugLog.write is a no-op for
-- both console print and file append. Flipped via DebugLog.setEnabled().
-- The shipping mod runs muted; only investigative sessions opt in.
local enabled = false

--- Truncate (or create) the log file and write a session header.
--- Safe to call from a pcall: failure here must not break init.
function DebugLog.init()
    local f, open_err = io.open(LOG_PATH, "w")
    if not f then
        print("[HeadTracking:LOG] could not open " .. LOG_PATH .. " for write: " .. tostring(open_err))
        return false
    end
    f:write(string.format("=== HeadTracking Lua log opened %s ===\n",
                          os.date("%Y-%m-%d %H:%M:%S")))
    f:close()
    initialized = true
    return true
end

--- Print to console and append to the log file with a timestamp. If the
--- file can't be opened (e.g. first call before init, or permission issue),
--- only the console print happens.
--- @param msg string
function DebugLog.write(msg)
    if not enabled then return end
    print(msg)
    local f = io.open(LOG_PATH, "a")
    if not f then return end
    f:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), msg))
    f:close()
end

--- Enable or disable the log. Off by default.
function DebugLog.setEnabled(on) enabled = on and true or false end
function DebugLog.isEnabled() return enabled end

--- Path (relative to mod folder) where log is being written, for info.
function DebugLog.path()
    return LOG_PATH
end

--- True once DebugLog.init() has successfully truncated the file.
function DebugLog.isInitialized()
    return initialized
end

return DebugLog
