-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo

local AimGeometry = {}

local math_sqrt = math.sqrt

function AimGeometry.compensateDirection(
        right, forward, up, source_forward, head_quat,
        position_x, position_y, position_z, aim_distance, position_active, w)
    local tx = source_forward.x * right.x
        + source_forward.y * right.y
        + source_forward.z * right.z
    local ty = source_forward.x * forward.x
        + source_forward.y * forward.y
        + source_forward.z * forward.z
    local tz = source_forward.x * up.x
        + source_forward.y * up.y
        + source_forward.z * up.z
    local source_length = math_sqrt(tx * tx + ty * ty + tz * tz)
    tx = tx / source_length
    ty = ty / source_length
    tz = tz / source_length

    if position_active then
        tx = tx * aim_distance - position_x
        ty = ty * aim_distance + position_y
        tz = tz * aim_distance - position_z
    end

    local qx = -head_quat.i
    local qy = -head_quat.j
    local qz = -head_quat.k
    local qw = head_quat.r
    local cx = qy * tz - qz * ty
    local cy = qz * tx - qx * tz
    local cz = qx * ty - qy * tx
    local vx = tx + 2 * (qw * cx + qy * cz - qz * cy)
    local vy = ty + 2 * (qw * cy + qz * cx - qx * cz)
    local vz = tz + 2 * (qw * cz + qx * cy - qy * cx)

    local dx = right.x * vx + forward.x * vy + up.x * vz
    local dy = right.y * vx + forward.y * vy + up.y * vz
    local dz = right.z * vx + forward.z * vy + up.z * vz
    local length = math_sqrt(dx * dx + dy * dy + dz * dz)

    return Vector4.new(dx / length, dy / length, dz / length, w)
end

return AimGeometry
