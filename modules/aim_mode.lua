-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Aim mode
-- The four ways of aiming down sights, and the three settings that store them.
-- Port of cameraunlock-core's cpp/include/cameraunlock/ads/aim_mode.h, which
-- CET cannot load.
--
--   mode              TrueFreeLook  FreeLookMarker  StockSights
--   SightsLocked      false         false           false
--   FreeLookMarker    true          true            false
--   TrueFreeLook      true          false           false
--   StockSights       false         false           true
--
-- StockSights wins over the other two. Without it, FreeLookMarker without
-- TrueFreeLook is sights locked: the marker belongs to free look, and the cycle
-- never writes that pair.

local AimMode = {}

AimMode.SIGHTS_LOCKED = "SightsLocked"
AimMode.FREE_LOOK_MARKER = "FreeLookMarker"
AimMode.TRUE_FREE_LOOK = "TrueFreeLook"
AimMode.STOCK_SIGHTS = "StockSights"

local ORDER = { AimMode.SIGHTS_LOCKED, AimMode.FREE_LOOK_MARKER, AimMode.TRUE_FREE_LOOK, AimMode.STOCK_SIGHTS }

local LABELS = {
    [AimMode.SIGHTS_LOCKED] = "Aim mode: sights locked",
    [AimMode.FREE_LOOK_MARKER] = "Aim mode: free look with marker",
    [AimMode.TRUE_FREE_LOOK] = "Aim mode: true free look",
    [AimMode.STOCK_SIGHTS] = "Aim mode: stock sights",
}

AimMode.ORDER = ORDER

--- @param free_look boolean|nil
--- @param marker boolean|nil
--- @param stock boolean|nil
--- @return string mode
function AimMode.decode(free_look, marker, stock)
    if stock then return AimMode.STOCK_SIGHTS end
    if not free_look then return AimMode.SIGHTS_LOCKED end
    if marker then return AimMode.FREE_LOOK_MARKER end
    return AimMode.TRUE_FREE_LOOK
end

--- @param mode string
--- @return boolean free_look, boolean marker, boolean stock
function AimMode.encode(mode)
    if mode == AimMode.FREE_LOOK_MARKER then return true, true, false end
    if mode == AimMode.TRUE_FREE_LOOK then return true, false, false end
    if mode == AimMode.STOCK_SIGHTS then return false, false, true end
    return false, false, false
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

--- Whether the lean stays honest on the camera while aiming. Stock sights eases
--- the whole lean out instead, so while it fades it hands the lean over as
--- sights locked does.
--- @param mode string
--- @return boolean
function AimMode.isFreeLook(mode)
    return mode == AimMode.FREE_LOOK_MARKER or mode == AimMode.TRUE_FREE_LOOK
end

--- Whether yaw, pitch and the lean ease out this frame. Feed it to an AdsFade of
--- its own: the fade's output is the share of those five that reaches the view.
--- Roll is never scaled by it.
--- @param mode string
--- @param aiming boolean
--- @return boolean
function AimMode.stockSightsEngaged(mode, aiming)
    return aiming and mode == AimMode.STOCK_SIGHTS
end

--- The head rotation that reaches the view under the stock sights share.
--- @param share number The stock sights fade: 1 at the hip, 0 with the sights up
--- @return number yaw, number pitch, number roll
function AimMode.stockPose(share, yaw, pitch, roll)
    return yaw * share, pitch * share, roll
end

--- @param mode string
--- @param sights_up number 0 at the hip, 1 with the sights up
--- @return number The aim marker's opacity, 0 outside free look with a marker
function AimMode.markerOpacity(mode, sights_up)
    if mode ~= AimMode.FREE_LOOK_MARKER then return 0.0 end
    return sights_up
end

return AimMode
