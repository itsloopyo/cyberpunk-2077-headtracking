-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Recenter capture: the neutral must be a RAW tracker sample.
--
-- Camera:apply() takes whatever pose it is handed as the new neutral, and the
-- pose it is handed comes from the interpolator. On the frame a recenter lands,
-- the interpolator is somewhere between the pre-press pose and the post-press
-- one - or still parked on the pre-press pose entirely, if that frame had no
-- fresh packet - so the captured neutral was a blend rather than anything the
-- tracker ever reported. The unresolved part becomes a permanent offset:
--
--   * tracker CENTER (HCAM trailer): the tracker zeroes its own output, so the
--     leftover is between nothing and the whole pre-press drift, MIRRORED - adj
--     is negated against the offset, so the view parks on the far side of
--     centre.
--   * hotkey: the tracker keeps reporting, so a press taken while the head is
--     moving stores a neutral that sits between two samples, and the user
--     pressed Home again.
--
-- At 60 fps on a 60 Hz tracker every frame carries a fresh sample and the blend
-- has already landed, so both cases come out exact. That is why this read as
-- correct. Above the tracker rate it is not.
--
-- Camera:prepareRecenterCapture() resets the interpolator while a capture is
-- armed, so the next sample parks on its raw value and the neutral is that
-- value exactly, at any frame rate, on both paths.
--
-- This drives the REAL camera and the REAL interpolator. The frame body below
-- mirrors the order in init.lua's onUpdateImpl: recenter arming, then
-- prepareRecenterCapture, then the interpolator, then apply.

local function assert_near(actual, expected, label, tol)
    tol = tol or 1e-4
    if type(actual) ~= "number" or math.abs(actual - expected) > tol then
        error(string.format("FAIL %s:\n  expected: %s (+-%s)\n  actual:   %s",
            label, tostring(expected), tostring(tol), tostring(actual)), 2)
    end
end

local function assert_true(cond, label)
    if not cond then error("FAIL " .. label, 2) end
end

-- CET stand-ins. apply() reaches the recenter capture before it looks for the
-- camera component, so a player with no FPP camera is enough to exercise the
-- capture and then bail out of the write path.
_G.Game = {
    GetPlayer = function()
        return { GetFPPCameraComponent = function() return nil end }
    end,
}

local PoseInterpolator = assert(loadfile("modules/poseinterpolator.lua"))()
local Camera = assert(loadfile("modules/camera.lua"))()

--- Minimal settings stand-in: defaults for everything, no observers.
local function stubSettings()
    return {
        get = function(_, _) return nil end,
        observe = function() return function() end end,
    }
end

local TRACKER_HZ = 60.0
local DRIFT = 8.0          -- degrees of pre-press drift
local RATES = { 60, 75, 100, 120, 144, 240 }

--- Run a recenter and report what got captured.
--- @param opts table {
---   fps: render rate,
---   zeroes: true = tracker CENTER (raw drops to 0 from the press frame on),
---           false = hotkey (tracker keeps reporting),
---   prepare: whether the frame calls prepareRecenterCapture,
---   ramp: degrees the reported pose moves per sample after the press (0 = still)
--- }
--- @return number neutral captured neutral yaw in degrees
--- @return table sent every raw yaw actually fed to the interpolator after the press
local function runRecenter(opts)
    local dt = 1.0 / opts.fps
    local sampleDt = 1.0 / TRACKER_HZ
    local camera = Camera.new(stubSettings())
    local interp = PoseInterpolator.new()
    local seq, acc = 0, 0
    local pressed = false
    local pose = DRIFT
    local sent = {}

    local function frame(press)
        if press then
            camera:recenter()
            pressed = true
        end
        if opts.prepare then camera:prepareRecenterCapture(interp) end

        acc = acc + dt
        local y, p, r
        if acc >= sampleDt then
            acc = acc - sampleDt
            seq = seq + 1
            if pressed then
                -- The zeroed packet is the one that carries the trailer, so the
                -- tracker's own CENTER takes effect on the press frame itself.
                if opts.zeroes then
                    pose = 0.0
                else
                    pose = pose + (opts.ramp or 0)
                end
                sent[#sent + 1] = pose
            end
            y, p, r = interp:update(pose, pose, pose, seq, dt)
        else
            y, p, r = interp:update(nil, nil, nil, nil, dt)
        end
        if y ~= nil then camera:apply(y, p, r, dt) end
    end

    -- Hold the pre-press pose long enough for the interval estimate to settle.
    for _ = 1, math.ceil(opts.fps * 40 / TRACKER_HZ) do frame(false) end
    frame(true)
    -- The capture stays armed until a sample lands, so let the burst continue.
    for _ = 1, math.ceil(opts.fps * 3 / TRACKER_HZ) do frame(false) end

    return camera:getRecenterOffset().yaw, sent
end

--- True when `value` is one of the poses the tracker actually reported.
local function isOneOf(value, sent)
    for _, s in ipairs(sent) do
        if math.abs(value - s) <= 1e-4 then return true end
    end
    return false
end

print("== recenter capture ==")

-- (1) Tracker CENTER: the neutral must be the zeroed raw pose, exactly, so the
-- view parks on centre rather than mirrored from the pre-press drift.
for _, fps in ipairs(RATES) do
    local neutral = runRecenter({ fps = fps, zeroes = true, prepare = true })
    assert_near(neutral, 0.0,
        string.format("tracker CENTER at %d fps captures the zeroed raw pose", fps))
end

-- (2) Hotkey with a still head: the tracker never zeroes, so the neutral must be
-- the pose it is still reporting - that is what makes one press resolve adj to
-- zero instead of leaving a residual to mash Home at.
for _, fps in ipairs(RATES) do
    local neutral = runRecenter({ fps = fps, zeroes = false, prepare = true })
    assert_near(neutral, DRIFT,
        string.format("hotkey at %d fps captures the reported pose", fps))
end

-- (3) Hotkey pressed while the head is MOVING. This is where the hotkey path
-- shows the same defect: mid-motion the interpolator output sits between two
-- samples, so the stored neutral is a pose the tracker never reported.
for _, fps in ipairs(RATES) do
    local neutral, sent = runRecenter({ fps = fps, zeroes = false, prepare = true, ramp = 2.0 })
    assert_true(#sent > 0, "the ramp scenario fed samples after the press")
    assert_near(neutral, sent[1], string.format(
        "moving-head hotkey at %d fps captures the first raw sample after the press", fps))
end

-- (4) The defect itself, pinned so the numbers cannot quietly come back.
do
    -- Tracker CENTER without the reset: the neutral keeps part or all of the
    -- pre-press drift everywhere the render rate outruns the tracker. 60 fps is
    -- the one rate that was already exact, which is why this went unnoticed.
    local residuals = {}
    for _, fps in ipairs(RATES) do
        residuals[fps] = (runRecenter({ fps = fps, zeroes = true, prepare = false }))
    end
    assert_near(residuals[60], 0.0, "60 fps was already exact (a frame is a whole sample period)")
    for _, fps in ipairs({ 75, 100, 120, 144, 240 }) do
        assert_true(math.abs(residuals[fps]) > 1.0, string.format(
            "without the reset, %d fps captures a blend (residual %.3f deg)",
            fps, residuals[fps]))
        -- Mirrored, and never worse than the whole drift: it is the pre-press
        -- pose leaking into the neutral, not a doubling of it. A press on a frame
        -- with no fresh packet leaks all of it.
        assert_true(residuals[fps] > 0 and residuals[fps] <= DRIFT + 1e-4, string.format(
            "residual at %d fps is between zero and the whole drift (%.3f)",
            fps, residuals[fps]))
    end

    -- Moving-head hotkey without the reset: the neutral is a pose the tracker
    -- never sent.
    local neutral, sent = runRecenter({ fps = 240, zeroes = false, prepare = false, ramp = 2.0 })
    assert_true(not isOneOf(neutral, sent), string.format(
        "without the reset, a moving-head press stores a blend (%.3f, never reported)", neutral))
end

print("== Recenter capture OK ==")
