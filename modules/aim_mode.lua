-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Aim mode
-- The three ways of handling a lean while aiming down sights, and the pair of
-- settings that stores them. Port of cameraunlock-core's
-- cpp/include/cameraunlock/ads/aim_mode.h, which CET cannot load.
--
--   mode              TrueFreeLook  FreeLookMarker
--   SightsLocked      false         false
--   FreeLookMarker    true          true
--   TrueFreeLook      true          false
--
-- FreeLookMarker without TrueFreeLook is sights locked: the marker belongs to
-- free look, and the cycle never writes that pair.

local AimMode = {}

AimMode.SIGHTS_LOCKED = "SightsLocked"
AimMode.FREE_LOOK_MARKER = "FreeLookMarker"
AimMode.TRUE_FREE_LOOK = "TrueFreeLook"

local ORDER = { AimMode.SIGHTS_LOCKED, AimMode.FREE_LOOK_MARKER, AimMode.TRUE_FREE_LOOK }

local LABELS = {
    [AimMode.SIGHTS_LOCKED] = "Aim mode: sights locked",
    [AimMode.FREE_LOOK_MARKER] = "Aim mode: free look with marker",
    [AimMode.TRUE_FREE_LOOK] = "Aim mode: true free look",
}

AimMode.ORDER = ORDER

--- @param free_look boolean|nil
--- @param marker boolean|nil
--- @return string mode
function AimMode.decode(free_look, marker)
    if not free_look then return AimMode.SIGHTS_LOCKED end
    if marker then return AimMode.FREE_LOOK_MARKER end
    return AimMode.TRUE_FREE_LOOK
end

--- @param mode string
--- @return boolean free_look, boolean marker
function AimMode.encode(mode)
    if mode == AimMode.FREE_LOOK_MARKER then return true, true end
    if mode == AimMode.TRUE_FREE_LOOK then return true, false end
    return false, false
end

--- @param mode string
--- @return string The mode the key steps to
function AimMode.next(mode)
    for i, candidate in ipairs(ORDER) do
        if candidate == mode then return ORDER[i % #ORDER + 1] end
    end
    error("Unknown aim mode: " .. tostring(mode))
end

--- @param mode string
--- @return string The toast and log line for the mode
function AimMode.label(mode)
    return LABELS[mode] or error("Unknown aim mode: " .. tostring(mode))
end

--- @param mode string
--- @param sights_up number 0 at the hip, 1 with the sights up
--- @return number The aim marker's opacity, 0 outside free look with a marker
function AimMode.markerOpacity(mode, sights_up)
    if mode ~= AimMode.FREE_LOOK_MARKER then return 0.0 end
    return sights_up
end

return AimMode
