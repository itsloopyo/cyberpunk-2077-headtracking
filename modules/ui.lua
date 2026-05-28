-- UI Module
-- On-screen notifications and status display for user feedback
-- Production-ready implementation with fade animations, queuing, and debug overlay
--
-- Features:
-- - Notification queue with automatic expiration
-- - Fade-in and fade-out animations
-- - Multiple notification display with stacking
-- - Optional debug overlay showing tracking status
-- - Configurable position, colors, and timing

local UI = {}
UI.__index = UI

-- Notification display constants
local NOTIFICATION_PADDING = 10
local NOTIFICATION_WIDTH = 250
local NOTIFICATION_CORNER_Y = 60   -- Distance from top
local FADE_IN_DURATION = 0.15      -- Seconds to fade in
local FADE_OUT_DURATION = 0.5      -- Seconds to fade out
local MAX_NOTIFICATIONS = 5        -- Maximum simultaneous notifications

-- Notification type colors (RGBA) - pre-defined to avoid allocations
local COLORS = {
    info = { r = 1.0, g = 1.0, b = 1.0, a = 1.0 },     -- White
    success = { r = 0.4, g = 0.9, b = 0.4, a = 1.0 },  -- Green
    warning = { r = 1.0, g = 0.8, b = 0.2, a = 1.0 },  -- Yellow
    error = { r = 1.0, g = 0.3, b = 0.3, a = 1.0 }     -- Red
}

-- Pre-cache os.clock for faster access
local os_clock = os.clock

-- Pre-cache math.huge for faster comparisons
local math_huge = math.huge

--- Validate number is finite
--- @param n number Number to validate
--- @return boolean valid Whether n is a finite number
local function isValidNumber(n)
    return type(n) == "number" and n == n and n ~= math_huge and n ~= -math_huge
end

--- Calculate alpha value with fade in/out animation
--- @param elapsed number Time elapsed since notification start
--- @param duration number Total duration of notification
--- @return number alpha Alpha value (0.0 to 1.0)
local function calculateAlpha(elapsed, duration)
    if not isValidNumber(elapsed) or not isValidNumber(duration) then
        return 0.0
    end

    if elapsed < 0 then
        return 0.0
    end

    -- Fade in phase
    if elapsed < FADE_IN_DURATION then
        return elapsed / FADE_IN_DURATION
    end

    -- Full visibility phase
    local fade_out_start = duration - FADE_OUT_DURATION
    if elapsed < fade_out_start then
        return 1.0
    end

    -- Fade out phase
    if elapsed < duration then
        return (duration - elapsed) / FADE_OUT_DURATION
    end

    return 0.0
end

--- Create a new UI manager instance
--- @return table UI instance
function UI.new()
    local self = setmetatable({}, UI)

    -- Active notifications queue
    self.notifications = {}

    -- Debug overlay state
    self.debug_enabled = false
    self.debug_info = {
        tracking_state = "Unknown",
        udp_stats = nil,
        camera_stats = nil
    }

    -- Reference to state module for debug info
    self.state = nil

    -- Statistics
    self.stats = {
        total_shown = 0,
        total_expired = 0
    }

    return self
end

--- Set the state module reference for debug overlay
--- @param state_ref table Reference to State module instance
function UI:setState(state_ref)
    self.state = state_ref
end

--- Enable or disable debug overlay
--- @param enabled boolean Whether to show debug overlay
function UI:setDebugEnabled(enabled)
    self.debug_enabled = enabled
end

--- Update debug info (called each frame if debug is enabled)
--- @param info table Debug information { tracking_state, udp_stats, camera_stats }
function UI:updateDebugInfo(info)
    if type(info) ~= "table" then
        return
    end
    self.debug_info = info
end

--- Show a notification message on screen
--- @param message string Text to display
--- @param duration number|nil How long to show (seconds, default: 2.0)
--- @param type string|nil Notification type: "info", "success", "warning", "error" (default: "info")
function UI:showNotification(message, duration, notification_type)
    -- Validate inputs
    if type(message) ~= "string" or #message == 0 then
        return
    end

    duration = duration or 2.0
    if not isValidNumber(duration) or duration <= 0 then
        duration = 2.0
    end

    notification_type = notification_type or "info"
    if not COLORS[notification_type] then
        notification_type = "info"
    end

    -- Limit queue size - remove oldest if full
    while #self.notifications >= MAX_NOTIFICATIONS do
        table.remove(self.notifications, 1)
        self.stats.total_expired = self.stats.total_expired + 1
    end

    -- Add new notification
    table.insert(self.notifications, {
        message = message,
        start_time = os_clock(),
        duration = duration,
        notification_type = notification_type
    })

    self.stats.total_shown = self.stats.total_shown + 1
end

--- Show a success notification (green)
--- @param message string Text to display
--- @param duration number|nil How long to show (seconds)
function UI:showSuccess(message, duration)
    self:showNotification(message, duration, "success")
end

--- Show a warning notification (yellow)
--- @param message string Text to display
--- @param duration number|nil How long to show (seconds)
function UI:showWarning(message, duration)
    self:showNotification(message, duration, "warning")
end

--- Show an error notification (red)
--- @param message string Text to display
--- @param duration number|nil How long to show (seconds)
function UI:showError(message, duration)
    self:showNotification(message, duration, "error")
end

--- Clear all active notifications
function UI:clearAll()
    self.stats.total_expired = self.stats.total_expired + #self.notifications
    self.notifications = {}
end

--- Get the number of active notifications
--- @return number count Number of active notifications
function UI:getActiveCount()
    return #self.notifications
end

--- Get statistics
--- @return table stats { total_shown, total_expired, currently_active }
function UI:getStats()
    return {
        total_shown = self.stats.total_shown,
        total_expired = self.stats.total_expired,
        currently_active = #self.notifications
    }
end

--- Reset statistics
function UI:resetStats()
    self.stats.total_shown = 0
    self.stats.total_expired = 0
end

--- Draw active notifications (called from onDraw)
--- Must be called every frame for animations to work
function UI:draw()
    local now = os_clock()
    local active = {}

    -- Filter out expired notifications and collect active ones
    for _, notif in ipairs(self.notifications) do
        local elapsed = now - notif.start_time
        if elapsed < notif.duration then
            table.insert(active, notif)
        else
            self.stats.total_expired = self.stats.total_expired + 1
        end
    end

    self.notifications = active

    -- Draw debug overlay if enabled
    if self.debug_enabled then
        self:drawDebugOverlay()
    end

    -- Nothing else to draw
    if #active == 0 then
        return
    end

    -- Position notifications in top-right area
    -- Use a reasonable fixed position since GetMainViewport isn't available in CET
    -- Window will auto-size and user can see it regardless of resolution
    local window_x = 1600  -- Works for 1080p+ resolutions (right side of screen)
    local window_y = NOTIFICATION_CORNER_Y

    ImGui.SetNextWindowPos(window_x, window_y)
    ImGui.SetNextWindowSize(NOTIFICATION_WIDTH, 0)

    -- Window flags for notification style
    local flags = ImGuiWindowFlags.NoTitleBar
    flags = flags + ImGuiWindowFlags.NoResize
    flags = flags + ImGuiWindowFlags.NoMove
    flags = flags + ImGuiWindowFlags.NoInputs
    flags = flags + ImGuiWindowFlags.AlwaysAutoResize
    flags = flags + ImGuiWindowFlags.NoSavedSettings
    flags = flags + ImGuiWindowFlags.NoFocusOnAppearing
    flags = flags + ImGuiWindowFlags.NoBringToFrontOnFocus

    -- Set window background with slight transparency
    ImGui.PushStyleColor(ImGuiCol.WindowBg, 0.1, 0.1, 0.1, 0.8)
    ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, 5.0)
    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, NOTIFICATION_PADDING, NOTIFICATION_PADDING)

    local visible = ImGui.Begin("HeadTrackingNotifications", flags)
    if visible then
        for i, notif in ipairs(active) do
            local elapsed = now - notif.start_time
            local alpha = calculateAlpha(elapsed, notif.duration)
            local color = COLORS[notif.notification_type] or COLORS.info

            -- Draw text with calculated alpha
            ImGui.TextColored(color.r, color.g, color.b, alpha * color.a, notif.message)

            -- Add spacing between multiple notifications (except last)
            if i < #active then
                ImGui.Spacing()
            end
        end
    end
    ImGui.End()

    ImGui.PopStyleVar(2)
    ImGui.PopStyleColor(1)
end

--- Draw debug overlay with tracking information
function UI:drawDebugOverlay()
    -- Position in top-left corner
    ImGui.SetNextWindowPos(10, 60)
    ImGui.SetNextWindowSize(280, 0)

    local flags = ImGuiWindowFlags.NoTitleBar
    flags = flags + ImGuiWindowFlags.NoResize
    flags = flags + ImGuiWindowFlags.NoMove
    flags = flags + ImGuiWindowFlags.NoInputs
    flags = flags + ImGuiWindowFlags.AlwaysAutoResize
    flags = flags + ImGuiWindowFlags.NoSavedSettings
    flags = flags + ImGuiWindowFlags.NoFocusOnAppearing

    ImGui.PushStyleColor(ImGuiCol.WindowBg, 0.0, 0.0, 0.0, 0.7)
    ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, 5.0)

    local visible = ImGui.Begin("HeadTrackingDebug", flags)
    if visible then
        ImGui.TextColored(0.8, 0.8, 1.0, 1.0, "=== Head Tracking Debug ===")
        ImGui.Spacing()

        -- Tracking state
        local state_color = { r = 0.5, g = 0.5, b = 0.5 }
        local state_text = self.debug_info.tracking_state or "Unknown"
        if state_text == "allowed" then
            state_color = { r = 0.2, g = 1.0, b = 0.2 }
        elseif state_text == "disabled" then
            state_color = { r = 1.0, g = 0.2, b = 0.2 }
        else
            state_color = { r = 1.0, g = 0.8, b = 0.2 }
        end
        ImGui.Text("State: ")
        ImGui.SameLine()
        ImGui.TextColored(state_color.r, state_color.g, state_color.b, 1.0, state_text)

        -- UDP stats
        if self.debug_info.udp_stats then
            local udp = self.debug_info.udp_stats
            ImGui.Text("UDP Packets: " .. tostring(udp.packets_received or 0))
            local receiving = udp.receiving and "Yes" or "No"
            ImGui.Text("Receiving: " .. receiving)
        end

        -- Camera stats
        if self.debug_info.camera_stats then
            local cam = self.debug_info.camera_stats
            ImGui.Spacing()
            ImGui.Text(string.format("Yaw: %.1f", cam.yaw or 0))
            ImGui.Text(string.format("Pitch: %.1f", cam.pitch or 0))
            ImGui.Text(string.format("Roll: %.1f", cam.roll or 0))
        end

        -- State module stats
        if self.state then
            ImGui.Spacing()
            ImGui.Text("Reason: " .. self.state:getStateDescription())
        end
    end
    ImGui.End()

    ImGui.PopStyleVar(1)
    ImGui.PopStyleColor(1)
end

return UI
