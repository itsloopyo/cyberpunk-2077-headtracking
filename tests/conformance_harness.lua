-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
--
-- Executor for the shared pipeline conformance vectors in
-- cameraunlock-core/data/pipeline-conformance.json.
--
-- The core owns the vectors, the constants and every assertion; this reads a
-- line-oriented command stream on stdin and prints one line of numbers per step.
-- See cameraunlock-core/scripts/pipeline-vectors/run-vectors.mjs for the
-- protocol, and `pixi run test-vectors` for the wiring.
--
-- Everything this cannot run is answered with an explicit `skip <reason>`, which
-- the runner reports separately from a pass. Most of what it skips is skipped
-- for the same reason: this mod links cameraunlock in its native DLL, so the
-- packet layer here is the core's own code and there is nothing ported to check.

local PoseInterpolator = assert(loadfile("modules/poseinterpolator.lua"))()

local unit_name, vector_id
local cfg = {}
local state = nil
local skipping = true

local function emit(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = string.format("%.10f", (select(i, ...)))
    end
    io.write(table.concat(parts, " "), "\n")
end

local function skip(reason)
    skipping = true
    state = nil
    io.write("skip ", reason, "\n")
end

-- Why each unit cannot run, in the words of what this port actually is.
local UNSUPPORTED = {
    position_interpolator =
        "position is passed through on packet frames only and never interpolated - see the note above the raw_x read in init.lua",
    position_processor =
        "the position pipeline works in the Cyberpunk camera frame, where the axes are permuted and two of them inverted, so its output is not comparable to the vector's pipeline-frame values axis for axis; tests/camera_position_test.lua covers it in its own frame",
    tracking_processor =
        "Camera:_smoothPose signs and clamps in one step and needs a live cached_settings; tests/camera_position_test.lua covers it in its own frame",
    euler_roundtrip =
        "the Lua half consumes Euler and composes quaternions through CET's Quaternion type, which has no standalone build",
    packet =
        "the packet layer is not ported: native/CMakeLists.txt links cameraunlock and native/src/UdpReceiver.cpp instantiates cameraunlock::UdpReceiver, so this is the core's own code and the core's own vectors already cover it",
    session_rot =
        "a session frame spans the native receiver and CET's camera API; neither can be driven from a script",
    session_pos =
        "a session frame spans the native receiver and CET's camera API; neither can be driven from a script",
}

local function configure()
    local reason = UNSUPPORTED[unit_name]
    if reason then
        skip(reason)
        return
    end
    if unit_name ~= "pose_interpolator" then
        skip("harness does not implement unit " .. unit_name)
        return
    end
    -- The interpolator exposes maxExtrapolationFraction and nothing else, so
    -- any other key means the vector is asking for something this port does not
    -- have. Running it anyway would report a pass for a different test.
    for key in pairs(cfg) do
        if key ~= "max_extrapolation_fraction" then
            skip("pose_interpolator has no setting for cfg key " .. key)
            return
        end
    end

    state = { interp = PoseInterpolator.new(), seq = 0 }
    if cfg.max_extrapolation_fraction then
        state.interp.maxExtrapolationFraction = cfg.max_extrapolation_fraction
    end
    skipping = false
    io.write("ok\n")
end

-- The interpolator takes a sample sequence rather than an is-this-new flag, so
-- the flag is turned back into one: bump on a new sample, repeat otherwise.
local function step(args)
    local yaw, pitch, roll = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    local is_new = args[4] ~= "0"
    local dt = tonumber(args[5])
    if is_new then
        state.seq = state.seq + 1
    end
    local oy, op, orr = state.interp:update(yaw, pitch, roll, state.seq, dt)
    emit(oy, op, orr)
end

for line in io.lines() do
    local args = {}
    for token in line:gmatch("%S+") do
        args[#args + 1] = token
    end
    local cmd = table.remove(args, 1)

    if cmd == "unit" then
        unit_name, vector_id = args[1], args[2]
        cfg = {}
        state = nil
        skipping = true
    elseif cmd == "cfg" then
        cfg[args[1]] = tonumber(args[2])
    elseif cmd == "begin" then
        configure()
    elseif cmd == "s" then
        if not skipping then step(args) end
    elseif cmd == "q" or cmd == "e" or cmd == "p" or cmd == "f" then
        assert(skipping, "harness accepted a unit it cannot step: " .. tostring(vector_id))
    elseif cmd == "end" then -- next `unit` resets
    elseif cmd == "bye" then
        break
    else
        error("unknown harness command: " .. tostring(cmd))
    end
end

io.stdout:flush()
