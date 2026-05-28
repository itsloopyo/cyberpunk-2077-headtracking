-- Tracking Data Receiver Module
-- Reads head pose from the native RED4ext plugin's TCP server.
--
-- Why TCP instead of shared memory: CET's Lua sandbox does not always expose
-- the LuaJIT FFI module (some CET versions ship without it, others gate it
-- behind a setting). RedSocket gives us a TCP socket that always works, and
-- the native plugin runs a tiny TCP server alongside its UDP receiver.
--
-- Port 4242 is shared between the UDP receiver (OpenTrack input) and the TCP
-- server (Lua read path) - same number, different protocols, no conflict.
-- Hardcoded on both sides so the two can't drift out of sync.
--
-- Protocol (over TCP):
--   client -> "G[,processed_yaw,processed_pitch,processed_roll,enabled,is_ads,qi,qj,qk,qr,propagator_inject]"
--   server -> "<seq>,<yaw:.4f>,<pitch:.4f>,<roll:.4f>[,<flags>]\r\n"

local TrackingInput = {}
TrackingInput.__index = TrackingInput

local DATA_FRESHNESS_WINDOW_S = 0.5

-- Max seconds we'll wait for a reply before assuming the request got lost
-- (game paused, alt-tab, TCP hiccup) and re-sending. Without this the
-- request_pending flag can wedge permanently and stall all tracking.
local REQUEST_TIMEOUT_S = 1.0

-- Reusable parsed-data table to avoid GC pressure.
local reusable_data = { yaw = 0, pitch = 0, roll = 0, x = 0, y = 0, z = 0, seq = 0 }

-- native_flags bit layout, mirrored in native/src/TcpServer.cpp. Bits 0-1 are
-- live status (hook activity); bits 2+ are one-shot edges that native sets
-- when a chord/key transitions to down, and Lua clears on consume.
local FLAG_HITSCAN_ACTIVE   = 1   -- bit 0
local FLAG_CAMERA_ACTIVE    = 2   -- bit 1
local FLAG_RECENTER         = 4   -- bit 2
local FLAG_TOGGLE_TRACKING  = 8   -- bit 3
local FLAG_CYCLE_MODE       = 16  -- bit 4
local FLAG_TOGGLE_YAW       = 32  -- bit 5

local function hasFlag(flags, bit)
    return (math.floor(flags / bit) % 2) >= 1
end

-- Module-level state shared with the RedSocket callback (callbacks fire
-- outside any TrackingInput method, so they can't easily reach instance
-- fields).
local data_updated = false
local total_packets = 0
local highest_seq = 0
local request_pending = false
local request_sent_time = nil  -- os.clock() when pending request went out
local last_successful_parse_time = nil
local native_flags = 0
local native_recenter_requested = false
local native_toggle_tracking_requested = false
local native_cycle_mode_requested = false
local native_toggle_yaw_requested = false

local function parseTrackingData(data)
    if not data or data == "" then return false end

    -- Format (native/src/TcpServer.cpp):
    --   <seq>,<yaw>,<pitch>,<roll>,<flags>[,<x>,<y>,<z>]\r\n
    -- The position triple is appended at the end; older native plugins
    -- that pre-date 6DOF omit it, so the match is optional-tail.
    local seq_str, yaw_str, pitch_str, roll_str, flags_str, x_str, y_str, z_str =
        data:match("(%d+),([%-%.%d]+),([%-%.%d]+),([%-%.%d]+),(%d+),?([%-%.%d]*),?([%-%.%d]*),?([%-%.%d]*)")
    if not seq_str then return false end

    local seq   = tonumber(seq_str)
    local yaw   = tonumber(yaw_str)
    local pitch = tonumber(pitch_str)
    local roll  = tonumber(roll_str)
    if not (seq and yaw and pitch and roll) then return false end
    if yaw ~= yaw or pitch ~= pitch or roll ~= roll then return false end  -- NaN

    local x = tonumber(x_str) or 0
    local y = tonumber(y_str) or 0
    local z = tonumber(z_str) or 0
    if x ~= x or y ~= y or z ~= z then x, y, z = 0, 0, 0 end

    total_packets = total_packets + 1
    request_pending = false
    request_sent_time = nil

    if seq <= highest_seq then return false end
    highest_seq = seq

    reusable_data.yaw = yaw
    reusable_data.pitch = pitch
    reusable_data.roll = roll
    reusable_data.x = x
    reusable_data.y = y
    reusable_data.z = z
    reusable_data.seq = seq
    native_flags = tonumber(flags_str) or 0
    if hasFlag(native_flags, FLAG_RECENTER)        then native_recenter_requested        = true end
    if hasFlag(native_flags, FLAG_TOGGLE_TRACKING) then native_toggle_tracking_requested = true end
    if hasFlag(native_flags, FLAG_CYCLE_MODE)      then native_cycle_mode_requested      = true end
    if hasFlag(native_flags, FLAG_TOGGLE_YAW)      then native_toggle_yaw_requested      = true end
    data_updated = true
    last_successful_parse_time = os.clock()
    return true
end

-- Boundary guard for RedSocket callbacks. These fire from RedSocket's dispatch
-- (outside any pcall of ours); an uncaught throw escapes to CET's panic path,
-- which in this stripped sandbox abort()s the process. Log the error to the
-- shared flushed crash-trace.log (same file init.lua's guard uses) and swallow,
-- so a stray error in packet handling can't crash the game.
-- Hoist the closure + reuse the args table. OnCommand fires per tracker
-- packet (60-120 Hz), so allocating a fresh table + closure each call was
-- visible GC pressure. RedSocket callbacks aren't reentrant on a single
-- wrapper, so the upvalue-reuse pattern is safe (same reasoning as
-- guardedVar in init.lua).
local _unpackFn = table.unpack or unpack
local function _socketGuard(name, fn)
    local args = {}
    local n = 0
    local function invoke() return fn(_unpackFn(args, 1, n)) end
    return function(...)
        local count = select("#", ...)
        n = count
        for i = 1, count do args[i] = select(i, ...) end
        local ok, err = pcall(invoke)
        if not ok then
            local f = io.open("crash-trace.log", "a")
            if f then
                f:write(string.format("[%s] CAUGHT in %s: %s\n", os.date("%H:%M:%S"), name, tostring(err)))
                f:close()
            end
            print("[HeadTracking] CAUGHT error in " .. name .. ": " .. tostring(err))
        end
    end
end

-- Hardcoded to match native/src/main.cpp kTcpPort. Both sides must agree and
-- there is no user-facing reason to customize this.
local TCP_PORT = 4242

-- Hoisted pcall trampolines. Calling `pcall(function() ... end)` allocates a
-- fresh closure per invocation. udp:poll() runs every frame, so the closure
-- on the SendCommand path was burning an allocation per frame. Defining the
-- helpers at module scope and calling pcall(_fn, args) avoids it.
local function _socketSendCommand(socket, cmd)
    socket:SendCommand(cmd)
end
local function _socketConnect(socket, host, port)
    socket:Connect(host, port)
end
local function _socketDisconnect(socket)
    socket:Disconnect()
end

function TrackingInput.new()
    local self = setmetatable({}, TrackingInput)
    self.port = TCP_PORT
    self.socket = nil
    self.initialized = false
    self.connected = false
    self.last_connect_attempt = 0
    self.connect_retry_interval = 3.0
    self.native_state = nil
    return self
end

function TrackingInput:init()
    -- RedSocket is a separate CET mod; if it isn't installed, we can't talk
    -- to the native plugin's TCP server at all.
    local ok, RedSocket = pcall(GetMod, "RedSocket")
    if not ok or not RedSocket then
        error("[HeadTracking] FATAL: RedSocket plugin not found. " ..
              "Install from https://github.com/rayshader/cp2077-red-socket")
    end

    self.socket = RedSocket.createSocket()
    if not self.socket then
        error("[HeadTracking] FATAL: RedSocket.createSocket() returned nil")
    end

    local this = self
    self.socket:RegisterListener(
        -- OnCommand: data received from server
        _socketGuard("RedSocket.OnCommand", function(command)
            parseTrackingData(command)
        end),
        -- OnConnection: status (0 = success)
        _socketGuard("RedSocket.OnConnection", function(status)
            if status == 0 then
                this.connected = true
                -- Clean slate on (re)connect so a wedged request doesn't
                -- survive across the disconnect.
                request_pending = false
                request_sent_time = nil
                print("[HeadTracking] Connected to native plugin TCP server")
            else
                this.connected = false
                print("[HeadTracking] TCP connect failed, status=" .. tostring(status))
            end
        end),
        -- OnDisconnection
        _socketGuard("RedSocket.OnDisconnection", function()
            this.connected = false
            request_pending = false
            request_sent_time = nil
            print("[HeadTracking] Disconnected from native plugin")
        end),
        -- OnError
        _socketGuard("RedSocket.OnError", function()
            request_pending = false
            request_sent_time = nil
            print("[HeadTracking] TCP socket error")
        end)
    )

    self.initialized = true
    self.last_connect_attempt = 0  -- forces immediate first attempt in poll()
    print("[HeadTracking] TCP tracking input ready (will connect on first poll, port " .. self.port .. ")")
    return true
end

function TrackingInput:isReady()
    return self.initialized
end

function TrackingInput:isDataFresh()
    if not last_successful_parse_time then return false end
    return (os.clock() - last_successful_parse_time) <= DATA_FRESHNESS_WINDOW_S
end

function TrackingInput:setNativeState(yaw, pitch, roll, enabled, is_ads, quat, propagator_inject)
    -- Reuse the state table to avoid a 10-field heap allocation every frame
    -- (this is called once per onUpdate via Aim:update). The table is left
    -- nil until the first call so poll()'s bootstrap "G" handshake on the
    -- pre-state frames is unchanged.
    local st = self.native_state
    if not st then
        st = {}
        self.native_state = st
    end
    st.yaw = yaw or 0
    st.pitch = pitch or 0
    st.roll = roll or 0
    st.enabled = enabled and 1 or 0
    st.is_ads = is_ads and 1 or 0
    st.qi = quat and quat.i or 0
    st.qj = quat and quat.j or 0
    st.qk = quat and quat.k or 0
    st.qr = quat and quat.r or 1
    st.propagator_inject = propagator_inject and 1 or 0
end

function TrackingInput:isNativeHitscanActive()
    return hasFlag(native_flags, FLAG_HITSCAN_ACTIVE)
end

function TrackingInput:isNativeCameraHookActive()
    return hasFlag(native_flags, FLAG_CAMERA_ACTIVE)
end

-- One-shot edge consumers. Each returns true exactly once per native
-- "key went down" event, then false until the next edge. Kept as four
-- explicit functions instead of a closure-based helper because they run
-- every frame and this module deliberately avoids per-frame allocations.
function TrackingInput:consumeNativeRecenterRequested()
    if native_recenter_requested then
        native_recenter_requested = false
        return true
    end
    return false
end

function TrackingInput:consumeNativeToggleTrackingRequested()
    if native_toggle_tracking_requested then
        native_toggle_tracking_requested = false
        return true
    end
    return false
end

function TrackingInput:consumeNativeCycleModeRequested()
    if native_cycle_mode_requested then
        native_cycle_mode_requested = false
        return true
    end
    return false
end

function TrackingInput:consumeNativeToggleYawRequested()
    if native_toggle_yaw_requested then
        native_toggle_yaw_requested = false
        return true
    end
    return false
end

function TrackingInput:secondsSinceLastPacket()
    if not last_successful_parse_time then return math.huge end
    return os.clock() - last_successful_parse_time
end

function TrackingInput:tryReconnect()
    if not self.socket then return end
    local now = os.clock()
    if (now - self.last_connect_attempt) < self.connect_retry_interval then
        return
    end
    self.last_connect_attempt = now
    print("[HeadTracking:TCP] Connecting to 127.0.0.1:" .. self.port)
    pcall(_socketConnect, self.socket, "127.0.0.1", self.port)
end

--- Poll for the latest tracking sample.
--- @return table|nil {yaw, pitch, roll}
function TrackingInput:poll()
    if not self.initialized then return nil end

    if not self.connected then
        self:tryReconnect()
        return nil
    end

    -- If a pending request has been outstanding longer than REQUEST_TIMEOUT_S,
    -- assume the reply is lost (game pause, socket hiccup, etc.) and let
    -- ourselves send a fresh one. Without this the pending flag can wedge
    -- permanently and kill tracking until a reload.
    if request_pending and request_sent_time
       and (os.clock() - request_sent_time) > REQUEST_TIMEOUT_S then
        request_pending = false
        request_sent_time = nil
    end

    -- Send a request only if we're not already waiting for one. Native plugin
    -- replies once per request, so this maintains a 1:1 ping-pong cadence.
    if not request_pending then
        local cmd = "G"
        local st = self.native_state
        if st then
            cmd = string.format(
                "G,%.6f,%.6f,%.6f,%d,%d,%.6f,%.6f,%.6f,%.6f,%d",
                st.yaw, st.pitch, st.roll, st.enabled, st.is_ads,
                st.qi, st.qj, st.qk, st.qr, st.propagator_inject)
        end
        local ok = pcall(_socketSendCommand, self.socket, cmd)
        if ok then
            request_pending = true
            request_sent_time = os.clock()
        end
    end

    if data_updated then
        data_updated = false
        return reusable_data
    end
    return nil
end

--- Publish a SNAP-CLEAN restore request over the TCP control channel.
--- The native plugin keeps a TCP server alongside its UDP listener; we
--- send the "R" command with the quaternion that should be written back
--- to cam.localOrientation once the hitscan has run. This is a fire-and-
--- forget one-way publish - there's no reply to parse, so it won't
--- interfere with the regular pose-poll ping-pong.
---
--- Returns true if the send was dispatched (not the same as "the native
--- side applied it"; that is observable via SHM's restore_ack_seq when
--- FFI is up). The caller should still run its fallback restore so the
--- tick budget isn't bet on a TCP round-trip we can't confirm.
--- @param qi number quaternion i
--- @param qj number quaternion j
--- @param qk number quaternion k
--- @param qr number quaternion r
--- @return boolean sent
function TrackingInput:sendRestore(qi, qj, qk, qr)
    if not self.connected or not self.socket then return false end
    local cmd = string.format("R,%.6f,%.6f,%.6f,%.6f", qi, qj, qk, qr)
    local ok = pcall(_socketSendCommand, self.socket, cmd)
    return ok == true
end

function TrackingInput:getStats()
    local now = os.clock()
    local is_receiving = last_successful_parse_time ~= nil and (now - last_successful_parse_time) < 1.0
    return {
        packet_count = total_packets,
        last_packet_time = last_successful_parse_time,
        is_receiving = is_receiving,
        connected = self.connected,
    }
end

function TrackingInput:resetStats()
    total_packets = 0
    last_successful_parse_time = nil
end

function TrackingInput:close()
    if self.socket and self.connected then
        pcall(_socketDisconnect, self.socket)
    end
    self.initialized = false
    self.connected = false
    print("[HeadTracking] TCP tracking input closed")
end

return TrackingInput
