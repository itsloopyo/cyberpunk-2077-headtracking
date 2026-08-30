-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Tests for the smoothing halves of modules/camera.lua.
--
-- These two functions had no test at all - camera.lua was covered only by the
-- syntax gate - and both carried a defect the shared conformance vectors in
-- cameraunlock-core describe. Neither vector can run against this file directly:
-- the position pipeline works in the Cyberpunk camera frame, where the axes are
-- permuted and two of them inverted, so its output is not comparable to the
-- vector's pipeline-frame values axis for axis. The behaviour is the same
-- behaviour, so it is pinned here in the frame it actually has.
--
-- Clamp before AND after smoothing (doctrine section 4). Clamping only the
-- output lets the smoothing state itself wind up far outside the limits, and the
-- output then sits pinned at a limit for hundreds of milliseconds after the head
-- has already come back. The native receiver publishes its raw position with no
-- bound of its own, so the input here really is unbounded.
--
-- First-sample snap. Without it the smoother blends up from zero after every
-- reset, and zero is not a pose anybody's head is in. reset() runs on every menu
-- exit, every load and every tracking toggle.

local Camera = assert(loadfile("modules/camera.lua"))()

local EPS = 1e-9

local function assert_near(actual, expected, label, tol)
    tol = tol or EPS
    if type(actual) ~= "number" or math.abs(actual - expected) > tol then
        error(string.format("FAIL %s:\n  expected: %s (+-%s)\n  actual:   %s",
            label, tostring(expected), tostring(tol), tostring(actual)), 2)
    end
end

local function assert_true(cond, label)
    if not cond then error("FAIL " .. label, 2) end
end

--- A Camera with only the state these two functions touch. Building one through
--- Camera.new would drag in the settings module and the CET globals; the point
--- here is the arithmetic.
local function bare_camera(overrides)
    local cam = setmetatable({}, Camera)
    cam.smooth_yaw, cam.smooth_pitch, cam.smooth_roll = 0, 0, 0
    cam.rot_has_value = false
    cam.pos_smooth = { x = 0, y = 0, z = 0 }
    cam.pos_has_value = false
    cam.is_remote_connection = false
    cam.cached_settings = {
        local_smoothing = 0.0,
        remote_smoothing = 0.15,
        clamp_yaw = 120.0,
        clamp_pitch = 90.0,
        clamp_roll = 45.0,
        position_limit_x = 0.30,
        position_limit_y_up = 0.20,
        position_limit_y_down = 0.20,
        position_limit_z_fwd = 0.40,
        position_limit_z_back = 0.10,
    }
    for k, v in pairs(overrides or {}) do
        cam.cached_settings[k] = v
    end
    return cam
end

local DT = 1 / 60

-- ---------------------------------------------------------------- position

do
    -- The first sample is taken whole, so a lean that is already inside the
    -- limits appears at its true magnitude on the frame it arrives rather than
    -- a fraction of the way there. 5 cm lateral, inverted into the camera frame.
    local cam = bare_camera()
    local x, y, z = cam:_smoothPosition(5, 0, 0, DT)
    assert_near(x, -0.05, "first sample lands whole (lateral)")
    assert_near(y, 0, "first sample lands whole (forward)")
    assert_near(z, 0, "first sample lands whole (vertical)")
end

do
    -- Without the snap the first frame is factor * target. At the local default
    -- the factor is ~0.565 at 60fps, so the camera would show about 56% of the
    -- lean - visibly wrong, and repeated after every menu exit.
    local cam = bare_camera()
    cam.pos_has_value = true
    local x = cam:_smoothPosition(5, 0, 0, DT)
    assert_true(math.abs(x) < 0.049,
        "control: without the snap the first frame is short of the target")
end

do
    -- Clamped before smoothing: a lean far past the limit must not leave the
    -- smoothing state outside it, so the frame after the head comes back is
    -- already heading home rather than pinned at the limit.
    local cam = bare_camera()
    cam.is_remote_connection = true
    for _ = 1, 60 do
        cam:_smoothPosition(500, 0, 0, DT) -- 5 m of lateral lean
    end
    local pinned = cam:_smoothPosition(500, 0, 0, DT)
    assert_near(pinned, -0.30, "saturated output sits at the limit", 1e-6)
    assert_near(cam.pos_smooth.x, -0.30,
        "smoothing state is bounded by the limit, not by the input", 1e-6)

    -- Head returns to a 0.5 cm lean, well inside the limits.
    local back = cam:_smoothPosition(0.5, 0, 0, DT)
    assert_true(math.abs(back) < 0.29,
        string.format("output pinned at the limit after the head returned: %s", back))
end

do
    -- The asymmetric limits, in the camera frame: forward (cam Y) gets the
    -- generous budget and backward the small one, up (cam Z) against down.
    local cam = bare_camera()
    local x, y, z = cam:_smoothPosition(1000, 1000, 1000, DT)
    assert_near(x, -0.30, "lateral clamps symmetrically")
    assert_near(y, -0.10, "backward lean gets the small budget")
    assert_near(z, 0.20, "upward gets the up limit")

    local cam2 = bare_camera()
    local x2, y2, z2 = cam2:_smoothPosition(-1000, -1000, -1000, DT)
    assert_near(x2, 0.30, "lateral clamps symmetrically the other way")
    assert_near(y2, 0.40, "forward lean gets the generous budget")
    assert_near(z2, -0.20, "downward gets the down limit")
end

-- ---------------------------------------------------------------- rotation

do
    -- Same snap for the pose. Yaw and roll are inverted at this step, which is
    -- the port's own convention and not what is under test here.
    local cam = bare_camera()
    cam:_smoothPose(30, 20, 10, DT)
    assert_near(cam.smooth_yaw, -30, "first pose lands whole (yaw)")
    assert_near(cam.smooth_pitch, 20, "first pose lands whole (pitch)")
    assert_near(cam.smooth_roll, -10, "first pose lands whole (roll)")
end

do
    -- And it is a FIRST-sample snap, not a permanent one: the second sample
    -- smooths as before.
    local cam = bare_camera()
    cam.is_remote_connection = true
    cam:_smoothPose(30, 0, 0, DT)
    cam:_smoothPose(60, 0, 0, DT)
    assert_true(cam.smooth_yaw > -60 and cam.smooth_yaw < -30,
        string.format("second sample should still smooth, got %s", cam.smooth_yaw))
end

do
    -- reset() must clear both flags, or the snap fires once per session instead
    -- of once per resume - which is the case that actually matters, because
    -- reset() is what runs on a menu exit.
    local cam = bare_camera()
    cam:_smoothPose(30, 0, 0, DT)
    cam:_smoothPosition(5, 0, 0, DT)
    assert_true(cam.rot_has_value, "rotation flag set after a sample")
    assert_true(cam.pos_has_value, "position flag set after a sample")

    -- suspend() reaches for the camera component, which does not exist here, so
    -- the flags are checked against the same clearing reset() performs.
    cam.rot_has_value = false
    cam.pos_has_value = false
    local x = cam:_smoothPosition(5, 0, 0, DT)
    assert_near(x, -0.05, "position snaps again after the flag is cleared")
end

print("== Camera smoothing OK ==")
