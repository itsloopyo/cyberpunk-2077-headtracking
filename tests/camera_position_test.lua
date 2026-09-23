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
--
-- Every-frame smoothing. The smoothing factor is derived from the render
-- deltaTime, so a smoother that only advanced on the frames a packet landed on
-- delivered a different rate than the configured one - half of it at 120fps
-- against a 60Hz tracker - and stepped at the tracker's rate while rotation
-- moved at the render rate.

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
    cam.zoom_factor = 1
    cam.rot_has_value = false
    cam.pos_smooth = { x = 0, y = 0, z = 0 }
    cam.pos_raw = { x = 0, y = 0, z = 0 }
    cam.pos_local = { x = 0, y = 0, z = 0 }
    cam.pos_has_value = false
    cam.pos_applied = false
    cam.is_remote_connection = false
    cam.cached_settings = {
        position_enabled = true,
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

do
    -- The smoother runs on every render frame, holding the last sample as its
    -- target on the frames between packets. The configured rate is continuous -
    -- alpha = 1 - exp(-speed * dt), speed = lerp(50, 0.1, smoothing) - so the
    -- time to close 90% of a gap is ln(10) / speed at any frame rate, to within
    -- one frame of quantisation. Advancing the EMA once per packet instead
    -- stretches that by the frame-to-packet ratio: twice as slow at 120fps on a
    -- 60Hz tracker, and half the frames showing no movement at all.
    local FPS, TRACKER_HZ = 120, 60
    local frame_dt = 1 / FPS
    local frames_per_packet = FPS / TRACKER_HZ
    local smoothing = 0.15 -- the remote_smoothing default
    local speed = 50.0 + (0.1 - 50.0) * smoothing
    local expected_settle = math.log(10) / speed

    local cam = bare_camera()
    cam.is_remote_connection = true
    cam:_smoothPosition(0, 0, 0, frame_dt) -- head at rest; the snap fires here

    local target = -0.10 -- 10 cm lateral, inverted into the camera frame
    local settle_frames, prev, stalled_at = nil, 0, nil
    for frame = 1, 600 do
        local x
        if (frame - 1) % frames_per_packet == 0 then
            x = cam:_smoothPosition(10, 0, 0, frame_dt)
        else
            x = cam:_smoothPosition(nil, nil, nil, frame_dt)
        end
        if not settle_frames then
            if x == prev and not stalled_at then stalled_at = frame end
            if x <= target * 0.9 then settle_frames = frame end
        end
        prev = x
    end

    assert_true(stalled_at == nil, string.format(
        "output held still on frame %s: a frame with no fresh packet must still "
        .. "advance the smoother", tostring(stalled_at)))
    assert_true(settle_frames ~= nil, "position never reached 90% of the target")
    local settle = settle_frames * frame_dt
    assert_true(settle <= expected_settle + frame_dt, string.format(
        "90%% settle took %.4fs; the configured smoothing asks for %.4fs (+-one "
        .. "frame). Advancing once per packet gives %.4fs.",
        settle, expected_settle, expected_settle * frames_per_packet))
end

do
    -- A feed that stops has to settle on the last sample and stay on it. The
    -- target is constant between packets, so the EMA converges and holds; it
    -- cannot wind up over a menu, a loading screen or a tracker that went away.
    local cam = bare_camera()
    cam.is_remote_connection = true
    cam:_smoothPosition(0, 0, 0, DT)
    cam:_smoothPosition(10, 0, 0, DT)
    for _ = 1, 3600 do cam:_smoothPosition(nil, nil, nil, DT) end
    local x, y, z = cam:_smoothPosition(nil, nil, nil, DT)
    assert_near(x, -0.10, "settles on the last sample over a minute of dry frames", 1e-12)
    assert_near(y, 0, "no drift on the forward axis", 1e-12)
    assert_near(z, 0, "no drift on the vertical axis", 1e-12)
end

do
    -- With nothing held there is nothing to smooth toward, and saying so is what
    -- keeps a resume from running against a target from before the suspension.
    local cam = bare_camera()
    assert_true(cam:_smoothPosition(nil, nil, nil, DT) == nil,
        "no output before the first sample")

    cam:_smoothPosition(5, 0, 0, DT)
    -- suspend() reaches for the camera component, which does not exist here, so
    -- the state is cleared the same way suspend() clears it.
    cam.pos_has_value = false
    cam.pos_raw.x, cam.pos_raw.y, cam.pos_raw.z = 0, 0, 0
    assert_true(cam:_smoothPosition(nil, nil, nil, DT) == nil,
        "no output once the position state is cleared")
end

do
    -- local_smoothing defaults to 0 and the loopback path has to stay
    -- effectively instant, which running every frame only helps.
    local cam = bare_camera()
    cam:_smoothPosition(0, 0, 0, DT)
    local frames, x = 0, 0
    repeat
        frames = frames + 1
        x = cam:_smoothPosition(10, 0, 0, DT)
    until x <= -0.099 or frames > 60
    assert_true(frames <= 6, string.format(
        "local_smoothing 0 took %d frames (%.3fs) to close 99%% of a 10 cm lean",
        frames, frames * DT))
end

-- ---------------------------------------------------------------- rotation

do
    -- A zoomed camera scales yaw and pitch by its zoom factor; roll is left
    -- alone because it rotates the picture the same at any zoom.
    local cam = bare_camera()
    cam.zoom_factor = 0.5
    cam:_smoothPose(40, 20, 10, DT)
    assert_near(cam.smooth_yaw, -20, "yaw scaled by the zoom factor")
    assert_near(cam.smooth_pitch, 10, "pitch scaled by the zoom factor")
    assert_near(cam.smooth_roll, -10, "roll not scaled by the zoom factor")
end

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

-- ------------------------------------------- the position-enabled toggle

--- CET globals applyPosition reaches for. The chase-camera path needs none of
--- this, which is why the two cases below are not written the same way.
local function stub_cet()
    local written = {}
    local component = {
        SetLocalPosition = function(_, v) written[#written + 1] = v end,
    }
    Vector4 = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
    Game = {
        GetPlayer = function()
            return { GetFPPCameraComponent = function() return component end }
        end,
    }
    return written
end

--- Lean hard enough that the smoother saturates at the lateral limit.
local function lean_to_the_limit(cam, apply)
    for _ = 1, 120 do apply(cam, 40, 0, 0, DT) end
    assert_near(cam.pos_local.x, -0.30, "lean saturates at the lateral limit")
end

do
    -- Turning positional tracking off used to zero pos_local and stop there,
    -- leaving pos_smooth, pos_raw and pos_has_value holding the lean. Turning it
    -- back on with the head straight then replayed most of that lean on the very
    -- first frame, because the smoother resumed from the old value instead of
    -- snapping to the new sample.
    local cam = bare_camera()
    lean_to_the_limit(cam, cam.applyChaseCamPosition)

    cam.cached_settings.position_enabled = false
    cam:applyChaseCamPosition(0, 0, 0, DT)
    assert_near(cam.pos_local.x, 0, "position off publishes no offset")

    cam.cached_settings.position_enabled = true
    cam:applyChaseCamPosition(0, 0, 0, DT)
    assert_near(cam.pos_local.x, 0, "head straight, so the first frame back is neutral")
    assert_true(not cam.pos_has_value or cam.pos_smooth.x == 0,
        "the smoother is not still holding the old lean")
end

do
    -- Same toggle on the first-person path, which additionally writes the
    -- camera component.
    local written = stub_cet()
    local cam = bare_camera()
    lean_to_the_limit(cam, cam.applyPosition)
    assert_true(cam.pos_applied, "the lean was written to the camera")

    cam.cached_settings.position_enabled = false
    cam:applyPosition(0, 0, 0, DT)
    assert_near(written[#written].x, 0, "position off writes the camera back to origin")
    assert_true(not cam.pos_applied, "position off clears the outstanding write")

    cam.cached_settings.position_enabled = true
    cam:applyPosition(0, 0, 0, DT)
    assert_near(cam.pos_local.x, 0, "head straight, so the first frame back is neutral")
    assert_near(written[#written].x, 0, "and nothing stale reaches the camera")
end

do
    -- suspend() and the toggle have to leave the same state behind, or the two
    -- resume paths disagree about whether the smoother is primed.
    local cam_toggle = bare_camera()
    lean_to_the_limit(cam_toggle, cam_toggle.applyChaseCamPosition)
    cam_toggle.cached_settings.position_enabled = false
    cam_toggle:applyChaseCamPosition(0, 0, 0, DT)

    local cam_suspend = bare_camera()
    lean_to_the_limit(cam_suspend, cam_suspend.applyChaseCamPosition)
    cam_suspend:_clearPositionState()

    for _, field in ipairs({ "pos_local", "pos_smooth", "pos_raw" }) do
        for _, axis in ipairs({ "x", "y", "z" }) do
            assert_near(cam_toggle[field][axis], cam_suspend[field][axis],
                string.format("toggle and suspend agree on %s.%s", field, axis))
        end
    end
    assert_true(cam_toggle.pos_has_value == cam_suspend.pos_has_value,
        "toggle and suspend agree on pos_has_value")
end

print("== Camera smoothing OK ==")
