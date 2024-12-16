local obj = {}
obj.__index = obj

obj.name = "ScreenDimmer"
obj.version = "1.7"
obj.author = "Modified"
obj.license = "MIT"

-- Configuration variables
obj.idleTimeout = 300
obj.dimPercentage = 10
obj.logging = true
obj.fadeDuration = 0.5
obj.fadeSteps = 20
obj.checkInterval = 10
obj.unlockGracePeriod = 5
obj.externalScreenNames = {
    "BenQ PD3225U"
    -- Add other external screen name patterns here
}

obj.originalBrightness = {}
obj.isDimmed = false
obj.isFading = false
obj.isEnabled = false
obj.isInitialized = false
obj.isRestoring = false
obj.dimmedBeforeSleep = false
obj.dimmedBeforeLock = false
obj.lockState = false
obj.lastWakeTime = 0
obj.lastUserAction = 0
obj.lastUnlockTime = 0
obj.lastUnlockEventTime = 0
obj.unlockTimer = nil
obj.unlockDebounceInterval = 15  -- 2 second debounce

-- Logging function
local function log(message, force)
    if force or obj.logging then
        print(os.date("%Y-%m-%d %H:%M:%S: ") .. message)
    end
end

-- Function to log all screens and their brightness
local function logScreenBrightness(label)
    local screens = hs.screen.allScreens()
    for i, s in ipairs(screens) do
        local b = s:getBrightness()
        log(label .. " - Screen " .. i .. " Brightness: " .. tostring(b))
    end
end

-- Start the ScreenDimmer
function obj:start(showMessage)
    if not self.isEnabled then
        self.stateChecker:start()
        self.userActionWatcher:start()
        self.caffeineWatcher:start()
        self.isEnabled = true

        if showMessage ~= false then
            hs.alert.show("Screen Dimmer Enabled")
            log("Screen Dimmer Enabled", true)
        end
    end
end

-- Stop the ScreenDimmer
function obj:stop()
    if self.isEnabled then
        self.stateChecker:stop()
        self.userActionWatcher:stop()
        self.caffeineWatcher:stop()
        self.isEnabled = false
        self:restoreBrightness()
        hs.alert.show("Screen Dimmer Disabled")
        log("Screen Dimmer Disabled", true)
    end
end

-- Toggle the ScreenDimmer
function obj:toggle()
    if self.isEnabled then
        self:stop()
    else
        self:start()
    end
end

-- Bind hotkeys
function obj:bindHotkeys(mapping)
    local spec = {
        toggle = function() self:toggle() end
    }
    hs.spoons.bindHotkeysToSpec(spec, mapping)
end

-- Verify m1ddc functionality
function obj:verifyM1DDC()
    log("Verifying m1ddc functionality...")
    local cmd = "/opt/homebrew/bin/m1ddc display list"
    local output, status, type, rc = hs.execute(cmd)
    log(string.format("m1ddc displays check - output: %s, status: %s, type: %s, rc: %s", 
        tostring(output), tostring(status), tostring(type), tostring(rc)))
    return status
end

-- Detect DDC-capable screens
function obj:detectDDCCapableScreens()
    log("Detecting DDC-capable external screens...", true)
    local screens = self:getAllScreens()
    local ddcScreens = {}
    
    for _, screen in ipairs(screens) do
        -- Assume that internal displays contain "Retina" or "Built-in" in their name
        if not screen:name():match("Retina") and not screen:name():match("Built-in") then
            local id = screen:id()
            -- Attempt to get brightness using m1ddc
            local cmd = string.format("/opt/homebrew/bin/m1ddc get luminance -d %d", id)
            log("Executing DDC detection command: " .. cmd)
            local output, status, type, rc = hs.execute(cmd)
            if status and tonumber(output) then
                ddcScreens[id] = screen
                log(string.format("Screen '%s' (ID: %d) is DDC-capable with brightness: %s%%", 
                    screen:name(), id, output))
            else
                log(string.format("Screen '%s' (ID: %d) is NOT DDC-capable or command failed.", 
                    screen:name(), id))
            end
        else
            log(string.format("Screen '%s' (ID: %d) identified as internal; skipping DDC check.", 
                screen:name(), screen:id()))
        end
    end
    
    self.ddcScreens = ddcScreens
    log("DDC-capable screens detection completed.", true)
end

-- Print all screens and their IDs
function obj:printScreens()
    local screens = hs.screen.allScreens()
    for _, screen in ipairs(screens) do
        log(string.format("Screen '%s' has ID: %d", screen:name(), screen:id()))
    end
end

-- Initialize the ScreenDimmer
function obj:init()
    if self.isInitialized then
        return self
    end

    log("Initializing ScreenDimmer", true)
    if not self:verifyM1DDC() then
        log("WARNING: m1ddc verification failed!", true)
    end
    log("idleTimeout: " .. self.idleTimeout, true)
    log("dimPercentage: " .. self.dimPercentage, true)
    log("logging: " .. tostring(self.logging), true)

    self.lastWakeTime = hs.timer.secondsSinceEpoch()
    self.lastUserAction = self.lastWakeTime
    self.lastUnlockTime = self.lastWakeTime

    -- Detect DDC-capable screens
    self:detectDDCCapableScreens()

    -- Initialize isDimmed based on current screen brightness
    local screens = self:getAllScreens()
    local allDimmed = true
    for _, screen in ipairs(screens) do
        local brightness = self:getBrightness(screen)
        if brightness and brightness > (self.dimPercentage / 100) then
            allDimmed = false
            break
        end
    end
    self.isDimmed = allDimmed
    if self.isDimmed then
        log("Initialization detected already dimmed screens")
    else
        log("Initialization detected normal brightness screens")
    end

    self.stateChecker = hs.timer.new(self.checkInterval, function() self:checkAndUpdateState() end)

    self.userActionWatcher = hs.eventtap.new({
        hs.eventtap.event.types.keyDown,
        hs.eventtap.event.types.leftMouseDown,
        hs.eventtap.event.types.rightMouseDown,
        hs.eventtap.event.types.mouseMoved,
        hs.eventtap.event.types.flagsChanged,
        hs.eventtap.event.types.scrollWheel
    }, function(event)
        if self.lockState then
            log("Ignoring user action while system is locked")
            return false
        end

        local now = hs.timer.secondsSinceEpoch()
        -- Skip if we're in the unlock debounce period
        if (now - self.lastUnlockEventTime) < self.unlockDebounceInterval then
            log("Ignoring user action during unlock debounce period")
            return false
        end

        self.lastUserAction = now
        self:userInteractionDetected()

        if self.isDimmed then
            log("User action while dimmed, restoring brightness")
            hs.timer.doAfter(0.1, function()
                self:restoreBrightness()
            end)
        end
        return false
    end)

    self.caffeineWatcher = hs.caffeinate.watcher.new(function(eventType)
        self:caffeineWatcherCallback(eventType)
    end)

    hs.alert.show("Screen Dimmer Initialized")
    self:start(false)

    self.isInitialized = true
    return self
end

-- Caffeine watcher callback
function obj:caffeineWatcherCallback(eventType)
    log("Caffeinate event: " .. eventType, true)
    local now = hs.timer.secondsSinceEpoch()

    if eventType == hs.caffeinate.watcher.screensDidLock then
        self.lockState = true
        if self.isDimmed then
            self.dimmedBeforeLock = true
            log("Locked while dimmed")
        end

    elseif eventType == hs.caffeinate.watcher.screensDidUnlock then
        -- Debounce: Skip processing if within debounce interval
        if (now - self.lastUnlockEventTime) < self.unlockDebounceInterval then
            log("Ignoring extra unlock event within debounce interval")
            return
        end

        log("Processing unlock event")
        self.lastUnlockEventTime = now
        self.lockState = false
        self.lastUnlockTime = now
        self.lastUserAction = now

        -- Stop any existing timers
        if self.unlockTimer then self.unlockTimer:stop() end
        if self.stateChecker then self.stateChecker:stop() end

        -- Immediate brightness restore if dimmed and originalBrightness is set
        if self.isDimmed and next(self.originalBrightness) ~= nil then
            log("Restoring brightness after unlock")
            self:restoreBrightness()
        else
            log("No need to restore brightness after unlock")
        end

        -- Force an immediate system idle reset for TouchID
        self:userInteractionDetected()

        -- Set a single timer for restarting the state checker
        hs.timer.doAfter(self.unlockGracePeriod, function()
            log("Re-starting state checker after unlock grace period")
            self.lastUserAction = hs.timer.secondsSinceEpoch()  -- Reset user action time
            if self.stateChecker then
                self.stateChecker:start()
            end
        end)

    elseif eventType == hs.caffeinate.watcher.systemDidWake then
        self.lastWakeTime = now
        self.lastUserAction = now
        if self.stateChecker then self.stateChecker:stop() end

        hs.timer.doAfter(1, function()
            if self.dimmedBeforeSleep then
                log("Woke from sleep, was dimmed, restoring brightness")
                self:restoreBrightness()
            end
            self:resetState()

            hs.timer.doAfter(self.unlockGracePeriod, function()
                log("Re-starting state checker after wake grace period")
                if self.stateChecker then
                    self.stateChecker:start()
                end
            end)
        end)
    else
        log("Ignoring non-critical caffeinate event: " .. eventType)
    end
end

-- Configuration function
function obj:configure(config)
    log("Configuring variables...", true)
    if config then
        log(".. with calling values.", true)
        self.idleTimeout = config.idleTimeout or self.idleTimeout
        self.dimPercentage = config.dimPercentage or self.dimPercentage
        self.logging = config.logging or self.logging

        log("Configuration now:", true)
        log(string.format("  - idleTimeout: %s", tostring(self.idleTimeout)), true)
        log(string.format("  - dimPercentage: %s", tostring(self.dimPercentage)), true)
        log(string.format("  - logging: %s", tostring(self.logging)), true)
    end
    return self
end

-- Get all screens
function obj:getAllScreens()
    return hs.screen.allScreens()
end

-- FadeScreens function with proper fadeTimer scope
function obj:fadeScreens(screens, fromBrightnessTable, toBrightnessTable, callback)
    if self.isFading then
        log("fadeScreens called while already fading, waiting to complete")
        -- Optional: Queue the fade request or return
        return
    end
    self.isFading = true
    log("Fading screens from original brightness to target brightness", true)
    
    -- Configuration for step counts and durations
    local config = {
        externalSteps = 5,
        internalSteps = self.fadeSteps or 20,
        fadeDuration = self.fadeDuration or 2,
    }
    
    -- Separate screens by type using self.ddcScreens
    local internalScreens = {}
    local externalScreens = {}
    for _, screen in ipairs(screens) do
        local id = screen:id()
        if self.ddcScreens[id] then
            table.insert(externalScreens, screen)
        else
            table.insert(internalScreens, screen)
        end
    end
    
    -- Track completion
    local totalGroups = (#internalScreens > 0 and 1 or 0) + (#externalScreens > 0 and 1 or 0)
    local completedGroups = 0
    
    if totalGroups == 0 then
        log("No screens to fade")
        self.isFading = false
        if callback then callback() end
        return
    end
    
    -- Local function to handle group completion
    local function onGroupComplete()
        completedGroups = completedGroups + 1
        if completedGroups >= totalGroups then
            self.isFading = false
            if callback then callback() end
        end
    end
    
    -- Function to handle fading for a group of screens
    local function fadeGroup(screenGroup, steps, stepDuration, groupName)
        if #screenGroup == 0 then return end
        
        log(string.format("Starting fade for %s screens with %d steps", groupName, steps))
        local currentStep = 0
        
        -- Create timer in local scope
        local timer
        timer = hs.timer.doEvery(stepDuration, function()
            currentStep = currentStep + 1
            local progress = currentStep / steps
            
            for _, screen in ipairs(screenGroup) do
                local id = screen:id()
                local fromB = fromBrightnessTable[id] or 1.0
                local toB = toBrightnessTable[id] or 1.0
                local currentBrightness = fromB + (toB - fromB) * progress
                
                self:setBrightness(screen, currentBrightness)
            end
            
            if currentStep >= steps then
                -- Final brightness set
                for _, screen in ipairs(screenGroup) do
                    local id = screen:id()
                    local toB = toBrightnessTable[id] or 1.0
                    self:setBrightness(screen, toB)
                end
                
                -- Stop timer and mark group as complete
                timer:stop()
                onGroupComplete()
            end
        end)
    end
    
    -- Start fading each group
    if #internalScreens > 0 then
        fadeGroup(internalScreens, config.internalSteps, 
                 config.fadeDuration / config.internalSteps, "internal")
    end
    
    if #externalScreens > 0 then
        fadeGroup(externalScreens, config.externalSteps, 
                 config.fadeDuration / config.externalSteps, "external")
    end
end

-- Dim screens function
function obj:dimScreens()
    if self.isDimmed or not self.isEnabled then
        log("dimScreens called but already dimmed or not enabled")
        return
    end
    
    log("dimScreens called", true)
    local screens = self:getAllScreens()
    if #screens == 0 then
        log("No screens to dim")
        return
    end

    -- Clear and rebuild originalBrightness table
    self.originalBrightness = {}
    local validScreens = {}
    local fromBrightnessTable = {}
    local toBrightnessTable = {}
    local dimThreshold = self.dimPercentage / 100
    
    -- First pass: collect current brightness values
    for _, screen in ipairs(screens) do
        local id = screen:id()
        local currentBrightness = self:getBrightness(screen)
        
        -- Only dim screens that are actually brighter than our dim threshold
        if currentBrightness and currentBrightness > dimThreshold then
            log(string.format("Screen '%s' (ID: %d) will be dimmed from %.2f to %.2f", 
                screen:name(), id, currentBrightness, dimThreshold))
            
            self.originalBrightness[id] = currentBrightness
            table.insert(validScreens, screen)
            fromBrightnessTable[id] = currentBrightness
            toBrightnessTable[id] = dimThreshold
        else
            log(string.format("Screen '%s' (ID: %d) already at or below dim threshold (%.2f)", 
                screen:name(), id, currentBrightness or -1))
        end
    end

    if #validScreens == 0 then
        log("No screens need dimming")
        self.isDimmed = true  -- Mark as dimmed since all screens are already at or below threshold
        return
    end

    self:fadeScreens(validScreens, fromBrightnessTable, toBrightnessTable, function()
        self.isDimmed = true
        self.dimmedBeforeSleep = true
        log("Screens dimmed", true)
    end)
end

-- Restore brightness function
function obj:restoreBrightness()
    if self.lockState then
        log("Skipping brightness restore while system is locked")
        return
    end

    if self.isRestoring then
        log("restoreBrightness called while already restoring, ignoring")
        return
    end

    log("restoreBrightness called", true)

    if next(self.originalBrightness) == nil then
        log("No original brightness values stored, cannot restore")
        return
    end

    self.isRestoring = true
    local screens = self:getAllScreens()
    local validScreens = {}
    local fromBrightnessTable = {}
    local toBrightnessTable = {}

    -- Collect screens that have stored brightness values
    for _, screen in ipairs(screens) do
        local id = screen:id()
        if self.originalBrightness[id] ~= nil then
            table.insert(validScreens, screen)
            local currentBrightness = self:getBrightness(screen)
            fromBrightnessTable[id] = currentBrightness or self.originalBrightness[id]
            toBrightnessTable[id] = self.originalBrightness[id]
            log(string.format("Preparing to restore brightness for screen '%s' (ID: %d): from %.2f to %.2f", 
                screen:name(), id, fromBrightnessTable[id], toBrightnessTable[id]))
        else
            log(string.format("Skipping screen '%s' (ID: %d) during restore, no original brightness stored", 
                screen:name(), id))
        end
    end

    if #validScreens == 0 then
        log("No screens to restore")
        self.isRestoring = false
        return
    end

    log("Original brightness table before restore: " .. hs.inspect(self.originalBrightness))
    log("From brightness table: " .. hs.inspect(fromBrightnessTable))
    log("To brightness table: " .. hs.inspect(toBrightnessTable))

    self:fadeScreens(validScreens, fromBrightnessTable, toBrightnessTable, function()
        -- Reset state flags only after fade is complete
        self.isDimmed = false
        self.dimmedBeforeLock = false
        self.dimmedBeforeSleep = false
        self.lastUserAction = hs.timer.secondsSinceEpoch()
        self.lastUnlockTime = self.lastUserAction
        
        -- Log final state of all screens
        for _, screen in ipairs(validScreens) do
            local id = screen:id()
            local b = self:getBrightness(screen)
            log(string.format("Screen '%s' (ID: %d) final brightness: %.2f", screen:name(), id, b or -1))
        end

        -- Clear original brightness only after successful restore
        self.originalBrightness = {}
        self.isRestoring = false
        log("Brightness restored", true)
    end)
end

-- Determine if screens should dim
function obj:shouldDim()
    if not self.isEnabled then 
        log("shouldDim: disabled")
        return false 
    end
    
    local now = hs.timer.secondsSinceEpoch()
    local idleTime = now - self.lastUserAction
    local timeSinceUnlock = now - self.lastUnlockTime

    log(string.format("shouldDim check: idleTime=%.1f, timeSinceUnlock=%.1f, timeout=%.1f", 
        idleTime, timeSinceUnlock, self.idleTimeout))

    if timeSinceUnlock < self.unlockGracePeriod then
        log("shouldDim: in unlock grace period")
        return false
    end

    if idleTime >= self.idleTimeout then
        log("shouldDim: should dim due to idle timeout")
        return true
    end

    log("shouldDim: no dim needed")
    return false
end

-- Handle user interaction
function obj:userInteractionDetected()
    local now = hs.timer.secondsSinceEpoch()
    self.lastUserAction = now
    
    -- Optionally, reconcile system idle time by comparing to your lastUserAction.
    local systemIdle = hs.host.idleTime()
    local scriptIdle = now - self.lastUserAction
    -- If the systemIdle is significantly larger (e.g. more than 2 seconds difference), reset it:
    if (systemIdle - scriptIdle) > 2 then
        -- Force a silent key press to let macOS know there's been "recent" user input
        hs.eventtap.keyStroke({}, "f15", 0)
        log("System idle time reset via keyStroke F15")
    end
end

-- Check and update state based on idle time
function obj:checkAndUpdateState()
    local now = hs.timer.secondsSinceEpoch()
    local timeSinceUnlock = now - (self.lastUnlockTime or 0)
    local timeSinceUserAction = now - self.lastUserAction

    log(string.format(
      "Time checks - sinceUnlock: %.1f, sinceUserAction: %.1f",
      timeSinceUnlock, timeSinceUserAction
    ))

    if self.isRestoring then
        log("Skipping state check during active brightness restoration")
        return
    end

    if timeSinceUnlock < self.unlockGracePeriod then
        log(string.format("In unlock grace period (%.1f sec remaining)",
            self.unlockGracePeriod - timeSinceUnlock))
        return
    end

    if now - self.lastUnlockEventTime < self.unlockDebounceInterval + 1 then
        log("Skipping state check during unlock debounce period")
        return
    end

    local shouldDim = (timeSinceUserAction > self.idleTimeout)
    log(string.format("Checking state - Should dim: %s, Currently dimmed: %s, scriptIdle=%.1f",
        tostring(shouldDim), tostring(self.isDimmed), timeSinceUserAction))

    if shouldDim and not self.isDimmed then
        self:dimScreens()
    elseif not shouldDim and self.isDimmed then
        self:restoreBrightness()
    end
end

-- Reset state flags
function obj:resetState()
    log("resetState called", true)
    self.isDimmed = false
    self.isFading = false
    self.dimmedBeforeSleep = false
    self.dimmedBeforeLock = false
    self.lastUserAction = hs.timer.secondsSinceEpoch()
    self.lastUnlockTime = self.lastUserAction
    self.lastWakeTime = self.lastUserAction
    log("State reset completed")
end

-- Set brightness function with proper error handling
function obj:setBrightness(screen, brightness)
    -- Clamp brightness to [0.0, 1.0]
    brightness = math.max(0.0, math.min(1.0, brightness))
    
    log(string.format("setBrightness called for screen '%s' with brightness %.2f", screen:name(), brightness))
    
    if self.ddcScreens[screen:id()] then
        -- External display (DDC-capable)
        local brightnessPercent = math.floor(brightness * 100)
        local cmd = string.format("/opt/homebrew/bin/m1ddc set luminance %d -d %d", brightnessPercent, screen:id())
        log("Executing command: " .. cmd)
        local output, status, type, rc = hs.execute(cmd)
        if status then
            log(string.format("m1ddc set result for screen '%s' (ID: %d) - output: %s, rc: %s", 
                screen:name(), screen:id(), tostring(output), tostring(rc)))
        else
            log(string.format("Error setting brightness for screen '%s' (ID: %d): %s", 
                screen:name(), screen:id(), tostring(rc)))
            -- Optionally, handle the error (e.g., retry, notify user)
        end
    else
        -- Fallback to native method for other screens
        log("Using native brightness control for non-DDC-capable display")
        local success, err = pcall(function() screen:setBrightness(brightness) end)
        if success then
            log(string.format("Successfully set brightness for screen '%s' to %.2f", screen:name(), brightness))
        else
            log(string.format("Error setting brightness for screen '%s': %s", screen:name(), err))
            -- Optionally, handle the error
        end
    end
end

-- Get brightness function with proper error handling
function obj:getBrightness(screen)
    log(string.format("getBrightness called for screen '%s'", screen:name()))
    
    if self.ddcScreens[screen:id()] then
        -- External display (DDC-capable)
        local cmd = string.format("/opt/homebrew/bin/m1ddc get luminance -d %d", screen:id())
        log("Executing command: " .. cmd)
        local output, status, type, rc = hs.execute(cmd)
        log(string.format("m1ddc get result for screen '%s' (ID: %d) - output: %s, status: %s, type: %s, rc: %s", 
            screen:name(), screen:id(), tostring(output), tostring(status), tostring(type), tostring(rc)))
        
        if output and status then
            local brightness = tonumber(output:match("(%d+)"))
            if brightness then
                local normalized = brightness / 100
                log(string.format("Got DDC-capable brightness: %d%% (normalized: %.2f)", brightness, normalized))
                return normalized
            end
        end
        log("Failed to get DDC-capable brightness, falling back to native method")
    else
        -- Fallback to native method for other screens
        local brightness = screen:getBrightness()
        log(string.format("Got native brightness: %.2f", brightness or -1))
        return brightness
    end
    
    log("Returning fallback brightness value")
    return 1.0
end

return obj
