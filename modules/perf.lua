-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 itsloopyo
-- Performance Monitoring Module
-- Tracks frame timing, update rates, and performance metrics
-- Designed to have minimal overhead when not actively queried

local Perf = {}
Perf.__index = Perf

-- Pre-cache os.clock for timing
local os_clock = os.clock

-- Rolling window size for metrics (number of samples)
local SAMPLE_WINDOW = 60

--- Create a new performance monitor instance
--- @return table Perf instance
function Perf.new()
    local self = setmetatable({}, Perf)

    -- Frame timing tracking
    self.last_frame_time = nil
    self.frame_times = {}
    self.frame_index = 1

    -- Update timing tracking
    self.last_update_time = nil
    self.update_times = {}
    self.update_index = 1

    -- Counters
    self.frame_count = 0
    self.update_count = 0
    self.udp_packets = 0
    self.camera_updates = 0

    -- Peak tracking
    self.peak_frame_time = 0
    self.peak_update_time = 0

    -- Session start time
    self.start_time = os_clock()

    return self
end

--- Mark the start of a frame (call at beginning of onUpdate)
function Perf:frameStart()
    local now = os_clock()
    if self.last_frame_time then
        local delta = now - self.last_frame_time
        self.frame_times[self.frame_index] = delta
        self.frame_index = (self.frame_index % SAMPLE_WINDOW) + 1
        if delta > self.peak_frame_time then
            self.peak_frame_time = delta
        end
    end
    self.last_frame_time = now
    self.frame_count = self.frame_count + 1
end

--- Mark the start of an update cycle (when tracking data is processed)
function Perf:updateStart()
    self.last_update_time = os_clock()
end

--- Mark the end of an update cycle
function Perf:updateEnd()
    if self.last_update_time then
        local delta = os_clock() - self.last_update_time
        self.update_times[self.update_index] = delta
        self.update_index = (self.update_index % SAMPLE_WINDOW) + 1
        if delta > self.peak_update_time then
            self.peak_update_time = delta
        end
    end
    self.update_count = self.update_count + 1
end

--- Record a UDP packet received
function Perf:recordPacket()
    self.udp_packets = self.udp_packets + 1
end

--- Record a camera update applied
function Perf:recordCameraUpdate()
    self.camera_updates = self.camera_updates + 1
end

--- Calculate average from a rolling window array
--- @param samples table Array of samples
--- @return number average Average value or 0 if empty
local function calculateAverage(samples)
    local sum = 0
    local count = 0
    for _, v in pairs(samples) do
        if v then
            sum = sum + v
            count = count + 1
        end
    end
    return count > 0 and (sum / count) or 0
end

--- Get current performance metrics
--- @return table metrics Performance metrics
function Perf:getMetrics()
    local now = os_clock()
    local uptime = now - self.start_time

    local avg_frame_time = calculateAverage(self.frame_times)
    local avg_update_time = calculateAverage(self.update_times)

    return {
        -- Session info
        uptime_seconds = uptime,
        frame_count = self.frame_count,
        update_count = self.update_count,
        udp_packets = self.udp_packets,
        camera_updates = self.camera_updates,

        -- Frame timing (in milliseconds for readability)
        avg_frame_time_ms = avg_frame_time * 1000,
        peak_frame_time_ms = self.peak_frame_time * 1000,
        fps = avg_frame_time > 0 and (1.0 / avg_frame_time) or 0,

        -- Update timing (in microseconds - should be very fast)
        avg_update_time_us = avg_update_time * 1000000,
        peak_update_time_us = self.peak_update_time * 1000000,

        -- Rates
        packets_per_second = uptime > 0 and (self.udp_packets / uptime) or 0,
        updates_per_second = uptime > 0 and (self.camera_updates / uptime) or 0
    }
end

--- Get a compact one-line status string
--- @return string status Compact status string
function Perf:getStatusLine()
    local m = self:getMetrics()
    return string.format(
        "FPS: %.0f | Update: %.1fμs | Packets: %.0f/s",
        m.fps,
        m.avg_update_time_us,
        m.packets_per_second
    )
end

--- Reset all metrics (useful for benchmarking)
function Perf:reset()
    self.frame_times = {}
    self.frame_index = 1
    self.update_times = {}
    self.update_index = 1
    self.frame_count = 0
    self.update_count = 0
    self.udp_packets = 0
    self.camera_updates = 0
    self.peak_frame_time = 0
    self.peak_update_time = 0
    self.start_time = os_clock()
end

--- Reset peak values only
function Perf:resetPeaks()
    self.peak_frame_time = 0
    self.peak_update_time = 0
end

return Perf
