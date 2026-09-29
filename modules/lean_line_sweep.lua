-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Lean Line Sweep
-- A swept sphere for the lean clamp, built out of line casts. Port of
-- cameraunlock-core's cpp/include/cameraunlock/camera/lean_line_sweep.h, whose
-- tests (cpp/tests/lean_line_sweep_tests.cpp) tests/lean_line_sweep_test.lua
-- runs case for case.
--
-- One line along the lean guards the centre of the eye's path and nothing
-- around it: the eye can pass a door frame's edge, a shelf's lip or a table
-- corner a few millimetres off the line, and the near plane then culls the
-- corner and the player looks through it. A sphere swept along the lean is what
-- the eye needs kept clear, and this approximates it:
--
--  - one ray down the centre, which gives the exact answer for any flat surface
--    the lean runs into, at any angle;
--  - a ring of rays around it, parallel to the lean, on the sphere's equator,
--    which catches edges and corners the centre ray passes beside;
--  - a short sideways probe before each ring ray, so a ring ray never starts
--    inside a surface that is already closer to the eye than the radius.
--
-- The radius is the clamp's skin: the clamp holds the eye `skin` back from the
-- distance it is handed, so the sweep hands back the travel the sphere allows
-- PLUS the radius, and the two must be the same number.
--
-- The cast is function(sx, sy, sz, dx, dy, dz, length) returning
-- queried, hit, distance, nx, ny, nz. queried false means the cast could not
-- run. It must skip the player's own body: the eye starts inside it.
--
-- Pure: no game, no clock, no tables per cast.

local LeanLineSweep = {}

local TWO_PI = 6.28318530717958647692

--- @param cast function The engine's line cast, see above.
--- @param radius number The sphere's radius. Must equal the clamp's skin.
--- @param ring_rays number|nil Rays in the ring around the centre ray (8).
--- @param min_cosine number|nil Floor on the cosine between the lean and a
---   surface's normal (0.25). A flat surface met at an angle has to be traced
---   further along the lean to hold the eye `radius` off it, by radius / cos,
---   which has no bound at grazing incidence.
--- @return function query(start, direction, max_distance) in the shape the
---   lean clamp takes, returning { queried, blocked, distance }.
function LeanLineSweep.query(cast, radius, ring_rays, min_cosine)
    local r = radius
    local n = ring_rays or 8
    local min_cos = min_cosine or 0.25
    -- The ring's directions around the lean depend on the lean, but their
    -- angles do not.
    local cos_k, sin_k = {}, {}
    for k = 0, n - 1 do
        local angle = TWO_PI * k / n
        cos_k[k] = math.cos(angle)
        sin_k[k] = math.sin(angle)
    end

    local UNANSWERED = { queried = false, blocked = false, distance = 0 }
    local CLEAR = { queried = true, blocked = false, distance = 0 }
    local blocked = { queried = true, blocked = true, distance = 0 }

    return function(start, dir, max_distance)
        local sx, sy, sz = start.x, start.y, start.z
        local dx, dy, dz = dir.x, dir.y, dir.z
        local lean = max_distance - r
        -- The furthest the sphere's centre may travel, starting from the
        -- whole lean.
        local travel = lean

        -- Centre ray. For a flat surface at distance d whose normal is at cos c
        -- to the lean, the sphere touches it once its centre has gone d - r / c.
        local q, hit, dist, nx, ny, nz = cast(sx, sy, sz, dx, dy, dz, lean + r / min_cos)
        if not q then return UNANSWERED end
        if hit then
            local c = math.abs(dx * nx + dy * ny + dz * nz)
            if not (c > min_cos) then c = min_cos end
            local t = dist - r / c
            if t < travel then travel = t end
        end

        -- Two unit vectors perpendicular to the lean and to each other, crossed
        -- with the world axis least aligned with it so the cross never
        -- degenerates.
        local ax, ay, az = math.abs(dx), math.abs(dy), math.abs(dz)
        local hx, hy, hz
        if ax <= ay and ax <= az then
            hx, hy, hz = 1, 0, 0
        elseif ay <= az then
            hx, hy, hz = 0, 1, 0
        else
            hx, hy, hz = 0, 0, 1
        end
        local ux, uy, uz = dy * hz - dz * hy, dz * hx - dx * hz, dx * hy - dy * hx
        local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
        ux, uy, uz = ux / ul, uy / ul, uz / ul
        local vx, vy, vz = dy * uz - dz * uy, dz * ux - dx * uz, dx * uy - dy * ux

        for k = 0, n - 1 do
            local ck, sk = cos_k[k], sin_k[k]
            local px, py, pz = ux * ck + vx * sk, uy * ck + vy * sk, uz * ck + vz * sk

            -- Where on the ring this ray starts. A surface closer beside the eye
            -- than the radius pulls it in, halfway to that surface, so it starts
            -- in open space and runs parallel to the lean.
            local offset = r
            local pq, phit, pdist = cast(sx, sy, sz, px, py, pz, r)
            if not pq then return UNANSWERED end
            if phit and pdist < r then offset = pdist * 0.5 end

            -- A point at `offset` off the centre line is on the sphere's surface
            -- sqrt(r^2 - offset^2) ahead of the centre, so the sphere touches
            -- what this ray meets at d once its centre has gone d minus that.
            local ahead = math.sqrt(r * r - offset * offset)
            local rq, rhit, rdist = cast(sx + px * offset, sy + py * offset, sz + pz * offset,
                                         dx, dy, dz, lean + ahead)
            if not rq then return UNANSWERED end
            if rhit then
                local t = rdist - ahead
                if t < travel then travel = t end
            end
        end

        if travel >= lean then return CLEAR end
        -- The clamp subtracts its skin (== r) from this.
        blocked.distance = (travel > 0 and travel or 0) + r
        return blocked
    end
end

return LeanLineSweep
