-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- ADS entry-pose self-test. Runnable under stock lua.
--
-- Three rules here are easy to get wrong and invisible from the settings and
-- gate suites:
--   * the entry pose must be captured from a LIVE rotation, not from whatever
--     was last seen. The interpolator is reset on every suppressed frame and
--     returns nil until a fresh packet lands, so an ungated capture freezes a
--     pre-suppression pose and holds the whole aim at that offset.
--   * yaw wraps into -180..180, so the entry subtraction has to take the short
--     way round the seam. A plain a-b reads a 10-degree move as -350.
--   * roll is never made relative. It moves no aim point, so zeroing it on
--     entry only snaps a head tilt the player is holding back to level.

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("FAIL %s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

local function assert_near(actual, expected, label, tol)
    tol = tol or 1e-6
    if type(actual) ~= "number" or math.abs(actual - expected) > tol then
        error(string.format("FAIL %s: expected %s, got %s",
            label, tostring(expected), tostring(actual)), 2)
    end
end

local AdsPose = require("modules/ads_pose")

print("== ads entry pose ==")

-- 1. Hip fire passes the absolute pose straight through.
local p = AdsPose.new()
local y, pi, r, x, yy, z = p:update(false, 12, -5, 3, 0.1, 0.2, 0.3)
assert_eq(y, 12, "hip fire yaw passes through")
assert_eq(pi, -5, "hip fire pitch passes through")
assert_eq(r, 3, "hip fire roll passes through")
assert_eq(x, 0.1, "hip fire x passes through")
assert_eq(yy, 0.2, "hip fire y passes through")
assert_eq(z, 0.3, "hip fire z passes through")
assert_eq(p:isActive(), false, "no entry pose while hip firing")

-- 2. The frame the sights come up is identity: the view snaps onto the aim
--    point rather than staying wherever the head was.
y, pi, r, x, yy, z = p:update(true, 12, -5, 3, 0.1, 0.2, 0.3)
assert_eq(y, 0, "entry frame yaw is identity")
assert_eq(pi, 0, "entry frame pitch is identity")
assert_eq(r, 3, "entry frame keeps the absolute roll")
assert_eq(x, 0, "entry frame x is identity")
assert_eq(yy, 0, "entry frame y is identity")
assert_eq(z, 0, "entry frame z is identity")
assert_eq(p:isActive(), true, "entry pose captured")

-- 3. Movement from there still tracks, measured from the entry pose.
y, pi, r, x, yy, z = p:update(true, 22, 0, 8, 0.4, 0.2, 0.3)
assert_near(y, 10, "yaw tracks relative to entry")
assert_near(pi, 5, "pitch tracks relative to entry")
assert_near(r, 8, "roll stays absolute through the aim")
assert_near(x, 0.3, "x tracks relative to entry")
assert_near(yy, 0, "y tracks relative to entry")
assert_near(z, 0, "z tracks relative to entry")

-- 4. Lowering the sights returns the absolute pose.
y = p:update(false, 22, 0, 8, 0.4, 0.2, 0.3)
assert_eq(y, 22, "lowering the sights returns the absolute yaw")
assert_eq(p:isActive(), false, "entry pose dropped on the way out")

-- 5. Seam. Entry near +180 with the live pose just past it must read as the
--    small move it is, not its 360-degree complement. Roll needs no seam
--    handling because it is never differenced.
local seam = AdsPose.new()
seam:update(true, 175, 0, 178, 0, 0, 0)
y, pi, r = seam:update(true, -175, 0, -177, 0, 0, 0)
assert_near(y, 10, "yaw crossing +-180 takes the short way")
assert_near(r, -177, "roll passes through unchanged across the seam")

-- ... and the same in reverse.
local seam2 = AdsPose.new()
seam2:update(true, -175, 0, 0, 0, 0, 0)
y = seam2:update(true, 175, 0, 0, 0, 0, 0)
assert_near(y, -10, "yaw crossing -180 takes the short way")

-- Pitch is bounded to +-90 by the tracker's own asin and must stay a plain
-- difference: routing it through the seam logic would be wrong, not redundant.
local pitchcase = AdsPose.new()
pitchcase:update(true, 0, -80, 0, 0, 0, 0)
_, pi = pitchcase:update(true, 0, 85, 0, 0, 0, 0)
assert_near(pi, 165, "pitch is a plain difference, not wrapped")

-- 6. THE BUG. A suppressed stretch resets the interpolator, so the first frame
--    back has no rotation. Capturing then would freeze the pre-suppression
--    pose for the whole aim.
local gap = AdsPose.new()
gap:update(false, 12, -5, 3, 0.1, 0.2, 0.3)   -- hip fire, head at 12
gap:reset()                                    -- menu opens, tracking suppressed
-- Menu closes with the sights already up, but no fresh sample this frame.
y, pi, r, x = gap:update(true, nil, nil, nil, nil, nil, nil)
assert_eq(y, nil, "no rotation to apply on the frame with no sample")
assert_eq(gap:isActive(), false, "entry capture deferred past the empty frame")
-- The tracker's next sample is the head's REAL position (moved to 40 during
-- the menu). That is the entry pose, so the frame is identity.
y = gap:update(true, 40, -5, 3, 0.1, 0.2, 0.3)
assert_eq(y, 0, "entry captured from the first live sample, so the aim starts clean")
assert_eq(gap:isActive(), true, "entry pose captured once a sample arrives")
y = gap:update(true, 50, -5, 3, 0.1, 0.2, 0.3)
assert_near(y, 10, "and tracks from there")

-- 7. Position arrives on its own cadence: a frame with interpolated rotation
--    but no fresh packet must still hand back a relative rotation, and no
--    position rather than a stale one.
local mixed = AdsPose.new()
mixed:update(false, 0, 0, 0, 1.0, 2.0, 3.0)   -- last known position
y, pi, r, x, yy, z = mixed:update(true, 20, 0, 0, nil, nil, nil)
assert_eq(y, 0, "entry frame is identity even without a position packet")
assert_eq(x, nil, "no position packet means no position to apply")
-- The entry position came from the last packet, not from zero.
y, pi, r, x = mixed:update(true, 20, 0, 0, 1.5, 2.0, 3.0)
assert_near(x, 0.5, "entry position came from the last packet seen")

-- 8. reset() mid-aim re-arms the capture, so a suppression inside an aim does
--    not resume against the old entry pose.
local rearm = AdsPose.new()
rearm:update(true, 10, 0, 0, 0, 0, 0)
rearm:reset()
assert_eq(rearm:isActive(), false, "reset drops the entry pose")
y = rearm:update(true, 30, 0, 0, 0, 0, 0)
assert_eq(y, 0, "re-entry captures a fresh entry pose")

print("== ADS entry pose OK ==")
