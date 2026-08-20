-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Hotkey Sanity-Check Module
-- Runs at every mod init. For each of our actions:
--   - If already bound to anything non-zero, leave it alone.
--   - If missing or bound to 0 (CET's "unbound" marker), pick the first
--     default from the preferred/fallback list whose VK isn't already
--     claimed elsewhere in bindings.json.
--
-- Never touches other mods' sections or any HeadTracking action the user
-- deliberately set. Writes are atomic (temp + rename) and skipped entirely
-- if nothing changed.
--
-- CET reads bindings.json at its own startup, before this mod's onInit
-- fires, so changes we write here take effect on the NEXT game launch.
-- That's a one-time restart if the user wiped their binds; after that it
-- self-heals silently on every load.

local Hotkeys = {}

-- CET encodes bindings as (VK << 48). For VK 0-255 the bottom 48 bits are
-- zero and the top 8 come from VK, so the encoded value fits exactly in a
-- double - no precision loss through Lua/JSON.
local VK_SHIFT = 281474976710656  -- 2^48

-- Ordered list (not a keyed table) so conflict resolution is deterministic
-- across runs. Matches scripts/deploy.ps1 Merge-CetBindings exactly.
local CHOICES = {
    { action = "ToggleHeadTracking",     opts = {
        { vk = 0x23, name = "End"      },
        { vk = 0x61, name = "Numpad1"  },
        { vk = 0x7D, name = "F14"      },
    }},
    { action = "TogglePositionTracking", opts = {
        { vk = 0x21, name = "PageUp"   },
        { vk = 0x69, name = "Numpad9"  },
        { vk = 0x7E, name = "F15"      },
    }},
    { action = "ToggleYawMode",          opts = {
        { vk = 0x22, name = "PageDown" },
        { vk = 0x63, name = "Numpad3"  },
        { vk = 0x7F, name = "F16"      },
    }},
}

-- Path is relative to the mod's working dir, which CET sets to
-- cyber_engine_tweaks/mods/HeadTracking. Two levels up is
-- cyber_engine_tweaks/, where bindings.json lives.
local BINDINGS_PATH = "../../bindings.json"

local function getJson()
    if json then return json end  -- CET exposes this as a global
    local ok, mod = pcall(require, "json")
    return ok and mod or nil
end

local function readDoc(J)
    local f = io.open(BINDINGS_PATH, "r")
    if not f then return {}, "missing-or-first-run" end
    local content = f:read("*all")
    f:close()
    if not content or #content == 0 then return {}, "empty" end
    local ok, doc = pcall(J.decode, content)
    if not ok or type(doc) ~= "table" then
        return nil, "unparseable"
    end
    return doc, "ok"
end

local function writeDoc(J, doc)
    local ok, content = pcall(J.encode, doc)
    if not ok then return false, "encode-failed: " .. tostring(content) end

    local tmp = BINDINGS_PATH .. ".tmp"
    local bak = BINDINGS_PATH .. ".bak"
    local f, err = io.open(tmp, "w")
    if not f then return false, "open-tmp-failed: " .. tostring(err) end
    f:write(content)
    f:close()

    -- Two-step swap so a crash or rename failure never leaves bindings.json
    -- missing: we move the original aside, drop the new file in, and only
    -- then remove the backup. If the second rename fails, we restore.
    -- Windows os.rename refuses to overwrite, so each step must operate on
    -- a free destination.
    local original_exists = io.open(BINDINGS_PATH, "r")
    if original_exists then
        original_exists:close()
        os.remove(bak)
        local mok, merr = os.rename(BINDINGS_PATH, bak)
        if not mok then
            os.remove(tmp)
            return false, "backup-failed: " .. tostring(merr)
        end
    end

    local rok, rerr = os.rename(tmp, BINDINGS_PATH)
    if not rok then
        -- Best-effort restore: put the original back so the user doesn't
        -- lose every other mod's bindings.
        os.rename(bak, BINDINGS_PATH)
        os.remove(tmp)
        return false, "rename-failed: " .. tostring(rerr)
    end

    os.remove(bak)
    return true, "ok"
end

-- Walk every section of the file and collect VKs that are already claimed.
-- We won't pick a default that's in use - both to respect other mods'
-- binds and to avoid collisions between our own actions.
local function collectUsedVks(doc)
    local used = {}
    for _, section in pairs(doc) do
        if type(section) == "table" then
            for _, val in pairs(section) do
                if type(val) == "number" and val > 0 then
                    used[val] = true
                end
            end
        end
    end
    return used
end

--- Sanity-check and seed missing hotkey binds. Safe to call every launch.
--- Never overwrites an existing non-zero binding.
function Hotkeys.ensure()
    local J = getJson()
    if not J then
        print("[HeadTracking:Hotkeys] json module unavailable - skipping hotkey sanity check")
        return
    end

    local doc, status = readDoc(J)
    if doc == nil then
        -- Unparseable. Refuse to clobber a file we can't read - the user
        -- would lose every other mod's bindings too.
        print("[HeadTracking:Hotkeys] bindings.json " .. status .. " - skipping (refusing to overwrite what we can't parse)")
        return
    end

    doc.HeadTracking = doc.HeadTracking or {}
    local ht = doc.HeadTracking

    -- Retired actions: clear any stale bindings from previous mod versions
    -- so whatever keys they held are returned to the user / other mods.
    local RETIRED = { "ToggleReticle", "RecenterHeadTracking" }
    local dirty = false
    for _, action in ipairs(RETIRED) do
        if ht[action] ~= nil then
            ht[action] = nil
            dirty = true
            print("[HeadTracking:Hotkeys] cleared retired bind for " .. action)
        end
    end

    -- Scan after the retired clear, so a key a retired action was holding is
    -- available to allocate on this run rather than one launch later.
    local used = collectUsedVks(doc)

    local bound = {}
    local kept = {}
    local skipped = {}

    for _, entry in ipairs(CHOICES) do
        local action = entry.action
        local current = ht[action]

        if type(current) == "number" and current > 0 then
            table.insert(kept, action)
        else
            local picked
            for _, opt in ipairs(entry.opts) do
                local enc = opt.vk * VK_SHIFT
                if not used[enc] then
                    picked = opt
                    ht[action] = enc
                    used[enc] = true
                    dirty = true
                    break
                end
            end
            if picked then
                table.insert(bound, string.format("%s=%s", action, picked.name))
            else
                -- All choices taken. Leave it at 0 (unbound) rather than
                -- stealing another mod's key.
                if current ~= 0 then ht[action] = 0; dirty = true end
                table.insert(skipped, action)
            end
        end
    end

    if not dirty then
        print("[HeadTracking:Hotkeys] All hotkeys already bound.")
        return
    end

    local ok, err = writeDoc(J, doc)
    if not ok then
        print("[HeadTracking:Hotkeys] Could not write bindings.json: " .. tostring(err))
        return
    end

    local parts = {}
    if #bound   > 0 then table.insert(parts, "bound=[" .. table.concat(bound, ", ") .. "]") end
    if #kept    > 0 then table.insert(parts, "kept=["  .. table.concat(kept, ", ")  .. "]") end
    if #skipped > 0 then table.insert(parts, "skipped(all-choices-taken)=[" .. table.concat(skipped, ", ") .. "]") end

    print("[HeadTracking:Hotkeys] bindings.json updated: " .. table.concat(parts, " "))
    if #bound > 0 then
        print("[HeadTracking:Hotkeys] Restart the game once for CET to pick up the new binds.")
    end
end

return Hotkeys
