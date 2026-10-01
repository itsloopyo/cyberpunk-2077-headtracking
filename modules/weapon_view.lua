-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo

local WeaponView = {}
WeaponView.__index = WeaponView

function WeaponView.new()
    return setmetatable({}, WeaponView)
end

function WeaponView:release(cam)
    if self.weight == nil then return end
    if cam and cam.zoomWeaponOverrideWeight == self.written_weight
            and cam.zoomWeaponOverrideValue == self.written_value then
        cam.zoomWeaponOverrideWeight = self.weight
        cam.zoomWeaponOverrideValue = self.value
    end
    self.weight, self.value = nil, nil
    self.written_weight, self.written_value = nil, nil
end

function WeaponView:apply(cam)
    if not cam then
        self:release(nil)
        return
    end
    if self.weight == nil or cam.zoomWeaponOverrideWeight ~= self.written_weight
            or cam.zoomWeaponOverrideValue ~= self.written_value then
        self.weight = cam.zoomWeaponOverrideWeight
        self.value = cam.zoomWeaponOverrideValue
    end
    -- Both passes must project the sight line alike. Moving weapon components
    -- to compensate for unequal zoom separates them from the animated hands.
    cam.zoomWeaponOverrideWeight = cam.zoomOverrideWeight
    cam.zoomWeaponOverrideValue = cam.zoomOverrideValue
    self.written_weight = cam.zoomWeaponOverrideWeight
    self.written_value = cam.zoomWeaponOverrideValue
end

return WeaponView
