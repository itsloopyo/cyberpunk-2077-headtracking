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
local LeanClamp = require("modules.lean_clamp")

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
    cam.rig_local = { x = 0, y = 0, z = 0 }
    cam.rig_applied = false
    cam.rig_written = { x = 0, y = 0, z = 0 }
    cam.lean_clamp = LeanClamp.new(0.10, 0.9)
    cam.lean_last_eye = nil
    cam.lean_was_contact = false
    cam.lean_was_failed = false
    cam.lean_last_log = 0
    cam.view_turn = nil
    cam.rig_turned = false
    cam.rig_shift = { x = 0, y = 0, z = 0 }
    cam.view_counter = nil
    cam.view_logged = false
    cam.view_last_log = -10
    cam.is_remote_connection = false
    cam.cached_settings = {
        enabled = true,
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

local function v3(x, y, z) return { x = x, y = y, z = z } end

--- A player facing 30 degrees off world +Y, with the view pitched 35 degrees
--- down. The camera bone carries the pitch and the rig root does not, which is
--- what the game reports (GetLocalToWorld on EnvTriggerActivator and on root).
local YAW, PITCH = math.rad(30), math.rad(-35)
local ROOT_AXES = {
    X = v3(math.cos(YAW), -math.sin(YAW), 0),
    Y = v3(math.sin(YAW), math.cos(YAW), 0),
    Z = v3(0, 0, 1),
    W = v3(100, 200, 1.0),
}
local BONE_AXES = {
    X = ROOT_AXES.X,
    Y = v3(ROOT_AXES.Y.x * math.cos(PITCH), ROOT_AXES.Y.y * math.cos(PITCH), math.sin(PITCH)),
    Z = v3(-ROOT_AXES.Y.x * math.sin(PITCH), -ROOT_AXES.Y.y * math.sin(PITCH), math.cos(PITCH)),
    W = v3(100, 200, 2.7),
}

--- Where an offset written into a component with these axes puts the eye.
local function to_world(axes, v)
    return v3(v.x * axes.X.x + v.y * axes.Y.x + v.z * axes.Z.x,
              v.x * axes.X.y + v.y * axes.Y.y + v.z * axes.Z.y,
              v.x * axes.X.z + v.y * axes.Y.z + v.z * axes.Z.z)
end

--- CET globals applyPosition reaches for. The chase-camera path needs none of
--- this, which is why the cases below are not written the same way.
--- The level, as the raycast stub sees it: nil for open space, or a wall plane
--- given by a point on it and its normal. Every group answers the same.
local wall = nil
local raycasts = 0
-- The chase camera's clean pose as the native hook publishes it, or nil for
-- none published yet.
local chase_pose = nil

local function raycast(from, to)
    raycasts = raycasts + 1
    if not wall then return false, nil end
    local d = v3(to.x - from.x, to.y - from.y, to.z - from.z)
    local denom = d.x * wall.n.x + d.y * wall.n.y + d.z * wall.n.z
    if math.abs(denom) < 1e-12 then return false, nil end
    local t = ((wall.p.x - from.x) * wall.n.x + (wall.p.y - from.y) * wall.n.y
             + (wall.p.z - from.z) * wall.n.z) / denom
    if t < 0 or t > 1 then return false, nil end
    return true, { position = v3(from.x + d.x * t, from.y + d.y * t, from.z + d.z * t), normal = wall.n }
end

local function stub_cet()
    wall = nil
    raycasts = 0
    chase_pose = { p = v3(100, 200, 10), q = { i = 0, j = 0, k = 0, r = 1 } }
    local written = {}
    local rig_written = {}
    local component = {
        SetLocalPosition = function(_, v) written[#written + 1] = v end,
    }
    local rig = {
        SetLocalPosition = function(_, v) rig_written[#rig_written + 1] = v end,
        GetLocalToWorld = function() return ROOT_AXES end,
    }
    local bone = {
        GetLocalToWorld = function() return BONE_AXES end,
    }
    local by_name = { root = rig, EnvTriggerActivator = bone }
    Vector4 = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
    CName = { new = function(name) return name end }
    local player = {
        GetFPPCameraComponent = function() return component end,
        FindComponentByName = function(_, name)
            return assert(by_name[name], "no stub component " .. tostring(name))
        end,
    }
    local group_bits = { Static = 4, Terrain = 128, Dynamic = 8, Vehicle = 16 }
    QueryFilter = {
        ZERO = function() return { mask1 = 0, mask2 = 0 } end,
        AddGroup = function(name)
            return { mask1 = 0, mask2 = assert(group_bits[name], "no stub group " .. tostring(name)) }
        end,
    }
    Game = {
        GetPlayer = function() return player end,
        HeadTrackingSetFppOrientation = function() end,
        HeadTrackingChaseCameraPose = function()
            if not chase_pose then return false end
            local p, q = chase_pose.p, chase_pose.q
            return true, p.x, p.y, p.z, q.i, q.j, q.k, q.r
        end,
        GetSpatialQueriesSystem = function()
            return {
                SyncRaycastByQueryFilter = function(_, from, to, filter)
                    assert(filter.mask2 == 4 + 128 + 8 + 16, "the lean casts against all four groups at once")
                    return raycast(from, to)
                end,
            }
        end,
    }
    return written, rig_written
end

local function hip(cam, rx, ry, rz, dt) cam:applyPosition(rx, ry, rz, dt, 1.0, 0.0) end

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
    stub_cet()
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
    lean_to_the_limit(cam, hip)
    assert_true(cam.pos_applied, "the lean was written to the camera")

    cam.cached_settings.position_enabled = false
    hip(cam, 0, 0, 0, DT)
    assert_near(written[#written].x, 0, "position off writes the camera back to origin")
    assert_true(not cam.pos_applied, "position off clears the outstanding write")

    cam.cached_settings.position_enabled = true
    hip(cam, 0, 0, 0, DT)
    assert_near(cam.pos_local.x, 0, "head straight, so the first frame back is neutral")
    assert_near(written[#written].x, 0, "and nothing stale reaches the camera")
end

do
    -- suspend() and the toggle have to leave the same state behind, or the two
    -- resume paths disagree about whether the smoother is primed.
    stub_cet()
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


-- ----------------------------------------------- the chase camera's lean

do
    -- The chase camera's lean is swept from its own clean pose, in its own
    -- frame. Turned 90 degrees about Z, a lean along its local +X runs along
    -- world +Y, so a wall 0.15 m along world +Y holds it a skin off.
    stub_cet()
    local s = math.sqrt(0.5)
    chase_pose.q = { i = 0, j = 0, k = s, r = s }
    local cam = bare_camera()
    wall = { p = v3(100, 200.15, 10), n = v3(0, -1, 0) }
    cam:applyChaseCamPosition(-20, 0, 0, DT)
    assert_near(cam.pos_local.x, 0.05, "held a skin off a wall along the camera's own right", 1e-9)
    assert_true(cam.lean_clamp:inContact(), "contact is reported")

    wall = nil
    chase_pose = nil
    cam:applyChaseCamPosition(-20, 0, 0, DT)
    assert_near(cam.pos_local.x, 0, "no published pose, no lean")
end

-- ------------------------------------------- the lean between camera and rig

do
    -- At the hip the lean rides the camera alone and the rig is never touched:
    -- the arms, the weapon and the round stay with the body, as they always
    -- have.
    local written, rig_written = stub_cet()
    local cam = bare_camera()
    hip(cam, 10, 0, 0, DT)
    assert_near(written[#written].x, -0.10, "the camera carries the lean at the hip")
    assert_true(#rig_written == 0, "the rig is not written at the hip")
    assert_true(not cam.rig_applied, "and holds no offset")
end

do
    -- On the sights the rig carries it all, so the weapon comes with the eye,
    -- and the camera holds none of it. The aim hook and the reticle are handed
    -- the camera's share, which is zero: eye and round have moved together.
    local written, rig_written = stub_cet()
    local cam = bare_camera()
    cam:applyPosition(10, 0, 0, DT, 0.0, 1.0)
    assert_near(written[#written].x, 0, "the camera holds none of the lean on the sights")
    assert_near(cam.pos_local.x, 0, "so nothing opens a gap between eye and round")
    local rig = rig_written[#rig_written]
    assert_near(rig.x, -0.10, "a lateral lean is lateral in both frames", 1e-12)
    assert_near(rig.y, 0, "with no forward part", 1e-12)
    assert_near(rig.z, 0, "and no vertical part", 1e-12)
    assert_true(cam.rig_applied, "the rig holds the offset")
    local bx = cam:getRigPosition()
    assert_near(bx, -0.10, "the rig's share is reported in the camera bone's frame")
end

do
    -- The camera bone is pitched with the mouse and the root is not, so a
    -- forward lean on the rig has to be re-expressed or the eye goes somewhere
    -- else. Whatever the split, the eye lands where the whole lean on the camera
    -- would have put it - which is what keeps the view still while the lean
    -- changes hands on the way into the sights.
    local cases = { { 1.0, 0.0 }, { 0.75, 0.25 }, { 0.4, 0.6 }, { 0.0, 1.0 } }
    local expected = nil
    for _, shares in ipairs(cases) do
        local written, rig_written = stub_cet()
        local cam = bare_camera()
        cam:applyPosition(8, 5, -20, DT, shares[1], shares[2])
        local eye = to_world(BONE_AXES, written[#written])
        local r = rig_written and rig_written[#rig_written]
        if r then
            local rw = to_world(ROOT_AXES, r)
            eye = v3(eye.x + rw.x, eye.y + rw.y, eye.z + rw.z)
        end
        if not expected then
            expected = eye
        else
            local label = string.format("camera %.2f / rig %.2f", shares[1], shares[2])
            assert_near(eye.x, expected.x, label .. ": eye x unchanged", 1e-12)
            assert_near(eye.y, expected.y, label .. ": eye y unchanged", 1e-12)
            assert_near(eye.z, expected.z, label .. ": eye z unchanged", 1e-12)
        end
    end
    assert_true(math.abs(expected.z) > 0.05,
        "control: the pitched bone does put a forward lean partly into world z")
end

do
    -- The rig keeps an offset until something takes it back out: the game does
    -- not reset it. Dropping the rig's share, turning position off and
    -- suspending all have to write it back to the origin.
    local written, rig_written = stub_cet()
    local cam = bare_camera()
    cam:applyPosition(10, 0, 0, DT, 0.0, 1.0)
    hip(cam, 10, 0, 0, DT)
    assert_near(rig_written[#rig_written].x, 0, "leaving the sights puts the rig back")
    assert_true(not cam.rig_applied, "and clears the outstanding write")
    local count = #rig_written
    hip(cam, 10, 0, 0, DT)
    assert_true(#rig_written == count, "an idle rig is not rewritten every frame")

    cam:applyPosition(10, 0, 0, DT, 0.0, 1.0)
    cam.cached_settings.position_enabled = false
    cam:applyPosition(0, 0, 0, DT, 0.0, 1.0)
    assert_near(rig_written[#rig_written].x, 0, "position off puts the rig back")
    assert_true(not cam.rig_applied, "position off clears the rig's write")

    cam.cached_settings.position_enabled = true
    cam:applyPosition(10, 0, 0, DT, 0.0, 1.0)
    cam.last_head_quat = nil
    cam:suspend()
    assert_near(rig_written[#rig_written].x, 0, "suspend puts the rig back")
    assert_true(not cam.rig_applied, "suspend clears the rig's write")
    assert_near(cam.rig_local.x, 0, "and the rig's share")
end

-- ------------------------------------------------- the lean against the level

--- Distance from the eye after a lean to the wall plane, along its normal.
local function standoff(eye_world)
    local p, n = wall.p, wall.n
    return (eye_world.x - p.x) * n.x + (eye_world.y - p.y) * n.y + (eye_world.z - p.z) * n.z
end

--- Where the stubbed game would put the eye after one applyPosition.
local function eye_after(written, rig_written)
    local c = to_world(BONE_AXES, written[#written])
    local r = rig_written and rig_written[#rig_written]
    local rw = r and to_world(ROOT_AXES, r) or v3(0, 0, 0)
    return v3(BONE_AXES.W.x + c.x + rw.x, BONE_AXES.W.y + c.y + rw.y, BONE_AXES.W.z + c.z + rw.z)
end

do
    -- Open space: the lean is untouched, and the query did run.
    local written = stub_cet()
    local cam = bare_camera()
    hip(cam, 20, 0, 0, DT)
    assert_near(written[#written].x, -0.20, "open space leaves the lean alone")
    assert_true(raycasts > 0, "the level was queried")
    assert_true(not cam.lean_clamp:inContact(), "and no contact is reported")
end

do
    -- A wall 0.15 m to the side along the lean: the eye stops a skin off it, on
    -- the camera at the hip and on the rig on the sights alike.
    for _, shares in ipairs({ { 1.0, 0.0 }, { 0.0, 1.0 }, { 0.5, 0.5 } }) do
        local written, rig_written = stub_cet()
        local cam = bare_camera()
        local lean_dir = to_world(BONE_AXES, v3(-1, 0, 0))
        wall = { p = v3(BONE_AXES.W.x + lean_dir.x * 0.15, BONE_AXES.W.y + lean_dir.y * 0.15,
                        BONE_AXES.W.z + lean_dir.z * 0.15),
                 n = v3(-lean_dir.x, -lean_dir.y, -lean_dir.z) }
        cam:applyPosition(20, 0, 0, DT, shares[1], shares[2])
        local label = string.format("camera %.1f / rig %.1f", shares[1], shares[2])
        assert_near(standoff(eye_after(written, rig_written)), 0.10, label .. ": held a skin off the wall", 1e-9)
        assert_true(cam.lean_clamp:inContact(), label .. ": contact is reported")
    end
end

do
    -- A wall met at 60 degrees: the standoff is measured off the surface, not
    -- along the lean, so the eye must stop further back than a skin along it.
    local written = stub_cet()
    local cam = bare_camera()
    local lean_dir = to_world(BONE_AXES, v3(-1, 0, 0))
    local up = v3(0, 0, 1)
    -- A normal 60 degrees off the lean, still facing the eye.
    local c, sn = math.cos(math.rad(60)), math.sin(math.rad(60))
    local n = v3(-lean_dir.x * c + up.x * sn, -lean_dir.y * c + up.y * sn, -lean_dir.z * c + up.z * sn)
    wall = { p = v3(BONE_AXES.W.x + lean_dir.x * 0.25, BONE_AXES.W.y + lean_dir.y * 0.25,
                    BONE_AXES.W.z + lean_dir.z * 0.25), n = n }
    hip(cam, 30, 0, 0, DT)
    assert_near(standoff(eye_after(written)), 0.10, "a slanted wall still gets a full skin", 1e-9)
end

do
    -- The clean eye is the bone less the rig's own offset. With the rig already
    -- holding a lean, the query has to start where the eye would be without it,
    -- or the clamp measures from a point that is already against the wall.
    local written, rig_written = stub_cet()
    local cam = bare_camera()
    cam:applyPosition(20, 0, 0, DT, 0.0, 1.0)
    local held = rig_written[#rig_written]
    assert_near(cam.rig_written.x, held.x, "the rig's offset is remembered in its own frame")
    local lean_dir = to_world(BONE_AXES, v3(-1, 0, 0))
    wall = { p = v3(BONE_AXES.W.x + lean_dir.x * 0.25, BONE_AXES.W.y + lean_dir.y * 0.25,
                    BONE_AXES.W.z + lean_dir.z * 0.25),
             n = v3(-lean_dir.x, -lean_dir.y, -lean_dir.z) }
    -- The game moves the bone with the root; the stub's bone does not move, so
    -- move it by hand the way the root moved it.
    local rw = to_world(ROOT_AXES, held)
    local saved = BONE_AXES.W
    BONE_AXES.W = v3(saved.x + rw.x, saved.y + rw.y, saved.z + rw.z)
    cam:applyPosition(20, 0, 0, DT, 0.0, 1.0)
    local eye = eye_after(written, rig_written)
    BONE_AXES.W = saved
    local ex = v3(eye.x - rw.x, eye.y - rw.y, eye.z - rw.z)
    assert_near(standoff(ex), 0.10, "measured from the clean eye, the lean stops a skin off the wall", 1e-9)
end

do
    -- A teleport drops the old room's allowance rather than easing out of it.
    local written = stub_cet()
    local cam = bare_camera()
    local lean_dir = to_world(BONE_AXES, v3(-1, 0, 0))
    wall = { p = v3(BONE_AXES.W.x + lean_dir.x * 0.15, BONE_AXES.W.y + lean_dir.y * 0.15,
                    BONE_AXES.W.z + lean_dir.z * 0.15),
             n = v3(-lean_dir.x, -lean_dir.y, -lean_dir.z) }
    hip(cam, 20, 0, 0, DT)
    assert_true(cam.lean_clamp:inContact(), "held off the wall before the teleport")
    wall = nil
    local saved = BONE_AXES.W
    BONE_AXES.W = v3(saved.x + 50, saved.y, saved.z)
    hip(cam, 20, 0, 0, DT)
    BONE_AXES.W = saved
    assert_near(written[#written].x, -0.20, "the first frame after a teleport takes the full lean")
end

do
    -- The constructor, not bare_camera, is what the game runs. A constant the
    -- constructor reads but the file declares further down resolves to an
    -- undefined global there, which only a real construction shows: every
    -- other case in this file builds its own clamp.
    local settings = {
        get = function() return nil end,
        observe = function() return function() end end,
    }
    local cam = Camera.new(settings)
    stub_cet()
    local lean_dir = to_world(BONE_AXES, v3(-1, 0, 0))
    wall = { p = v3(BONE_AXES.W.x + lean_dir.x * 0.15, BONE_AXES.W.y + lean_dir.y * 0.15,
                    BONE_AXES.W.z + lean_dir.z * 0.15),
             n = v3(-lean_dir.x, -lean_dir.y, -lean_dir.z) }
    cam.cached_settings.position_enabled = true
    cam:applyPosition(20, 0, 0, DT, 1.0, 0.0)
    assert_true(cam.lean_clamp:inContact(), "a constructed camera clamps the lean")
end

-- ------------------------------------------------------------ weapon view

do
    -- Aiming with the head turned, on a weapon the game draws at a different
    -- zoom from the world. The rig takes a turn and the camera the opposite
    -- one; the zooms are the game's and stay as it set them.
    stub_cet()
    local fpp = {
        zoom = 1, zoomOverrideWeight = 1, zoomOverrideValue = 1.4996,
        zoomWeaponOverrideWeight = 1, zoomWeaponOverrideValue = 1.0,
        orientation = { i = 0, j = 0, k = 0, r = 1 },
        SetLocalPosition = function() end,
    }
    function fpp:GetLocalOrientation() return self.orientation end
    function fpp:SetLocalOrientation(q) self.orientation = { i = q.i, j = q.j, k = q.k, r = q.r } end
    local rig = {
        orientation = nil, position = nil,
        GetLocalToWorld = function() return ROOT_AXES end,
    }
    function rig:SetLocalOrientation(q) self.orientation = q end
    function rig:SetLocalPosition(v) self.position = v end
    local bone = { GetLocalToWorld = function() return BONE_AXES end }
    local by_name = { root = rig, EnvTriggerActivator = bone }
    local player = {
        GetFPPCameraComponent = function() return fpp end,
        FindComponentByName = function(_, name) return by_name[name] end,
    }
    Game.GetPlayer = function() return player end
    Quaternion = { new = function(i, j, k, r) return { i = i, j = j, k = k, r = r } end }
    local ahead = to_world(BONE_AXES, v3(0.03, 0.35, -0.08))
    local weapon = {
        GetWorldPosition = function()
            return v3(BONE_AXES.W.x + ahead.x, BONE_AXES.W.y + ahead.y, BONE_AXES.W.z + ahead.z)
        end,
    }
    GameObject = { GetActiveWeapon = function() return weapon end }

    -- What apply() leaves behind: the head on the camera, 12 degrees of yaw.
    local h = math.rad(12) / 2
    local head = { i = 0, j = 0, k = math.sin(h), r = math.cos(h) }
    local cam = bare_camera()
    fpp.orientation = head
    cam.last_head_quat = head
    cam._last_written_final_quat = head

    cam:applyWeaponView(true)
    assert_true(rig.orientation == nil, "mounted, the rig stays where the seat puts it")

    cam:applyWeaponView(false)
    assert_true(cam.rig_turned and cam.rig_applied, "the rig holds the weapon turn")
    assert_true(math.abs(rig.orientation.r) < 1 - 1e-6, "which is a real turn")
    assert_near(fpp.zoomWeaponOverrideValue, 1.0, "the weapon's zoom is left to the game")
    local WeaponView = require("modules.weapon_view")
    local back = WeaponView.qmul(cam.view_turn, fpp.orientation)
    assert_near(math.abs(back.i * head.i + back.j * head.j + back.k * head.k + back.r * head.r), 1,
        "the camera holds the opposite turn", 1e-9)

    -- The next frame's apply() has to find the clean orientation under both.
    local held = fpp.orientation
    local clean = WeaponView.qmul(WeaponView.qmul(WeaponView.qconj(cam.view_counter), held),
        WeaponView.qconj(head))
    assert_near(math.abs(clean.r), 1, "counter and head peel back to the clean camera", 1e-9)

    cam:suspend()
    assert_near(math.abs(fpp.orientation.r), 1, "suspend takes head and counter-turn off the camera", 1e-9)
    assert_near(math.abs(rig.orientation.r), 1, "and puts the rig's orientation back", 1e-12)
    assert_near(rig.position.x, 0, "and its position", 1e-12)
    assert_true(not cam.rig_turned and cam.view_counter == nil and cam.view_turn == nil,
        "with nothing left held")

    -- At the hip both zooms are the camera's own, and nothing is written.
    rig.orientation, rig.position = nil, nil
    fpp.zoomOverrideWeight, fpp.zoomWeaponOverrideWeight = 0, 0
    fpp.orientation = head
    cam._last_written_final_quat = head
    cam:applyWeaponView(false)
    assert_true(rig.orientation == nil and rig.position == nil, "matching zooms turn nothing")

    -- Sights down mid-turn: the rig goes back to carrying the lean alone.
    fpp.zoomOverrideWeight, fpp.zoomWeaponOverrideWeight = 1, 1
    cam.rig_written.x = -0.1
    cam:applyWeaponView(false)
    assert_true(cam.rig_turned, "turned again")
    cam.view_counter = nil
    fpp.zoomOverrideWeight, fpp.zoomWeaponOverrideWeight = 0, 0
    cam:applyWeaponView(false)
    assert_near(math.abs(rig.orientation.r), 1, "the turn comes back out", 1e-12)
    assert_near(rig.position.x, -0.1, "and the lean stays", 1e-12)
    assert_near(cam.rig_shift.x, -0.1, "with the eye measured from the lean again", 1e-12)

    Game.GetPlayer = function() return nil end
    cam.rig_turned, cam.view_turn = true, {}
    cam:applyWeaponView(false)
    assert_true(not cam.rig_turned and cam.view_turn == nil, "a load drops what was held")
end

print("== Camera smoothing OK ==")