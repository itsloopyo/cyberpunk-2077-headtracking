-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Syntax gate for every shipped Lua file.
--
-- loadfile() compiles without executing, so this catches syntax errors in
-- modules that can't be run outside the CET sandbox. It is deliberately a
-- COMPILE check only - no module here is executed.
--
-- This replaces the effectively-dead check in scripts/validate.sh, whose
-- `lua -e "loadfile('$f')"` fallback always exited 0 (loadfile returns
-- nil+err rather than raising, so the interpreter never saw a failure).

local is_windows = package.config:sub(1, 1) == "\\"

--- List modules/*.lua from disk so a newly added module is covered without
--- anyone remembering to update this file.
local function listModules()
    local cmd = is_windows and "dir /b modules\\*.lua 2>nul"
                            or "ls modules/*.lua 2>/dev/null"
    local pipe = assert(io.popen(cmd), "failed to spawn directory listing")
    local files = {}
    for raw in pipe:lines() do
        local name = raw:gsub("%s+$", "")
        if name ~= "" then
            -- `dir /b` prints bare names; `ls` prints the relative path.
            files[#files + 1] = name:match("^modules[/\\]") and name
                                or ("modules/" .. name)
        end
    end
    pipe:close()
    return files
end

local targets = { "init.lua" }
for _, m in ipairs(listModules()) do targets[#targets + 1] = m end

-- A listing that yields nothing means the enumeration broke (wrong cwd, no
-- shell). Passing silently would make this gate a no-op, which is the exact
-- failure mode being replaced - so fail loudly instead.
if #targets < 2 then
    error("syntax_test: found no modules/*.lua - run from the repo root", 0)
end

print("== Lua syntax gate ==")
local failures = 0
for _, path in ipairs(targets) do
    local chunk, err = loadfile(path)
    if chunk then
        print("  ok   " .. path)
    else
        failures = failures + 1
        print("  FAIL " .. path .. ": " .. tostring(err))
    end
end

if failures > 0 then
    error(string.format("%d file(s) failed to compile", failures), 0)
end
print(string.format("== All %d Lua files compile ==", #targets))
