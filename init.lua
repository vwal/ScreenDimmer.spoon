local obj = {
    __index = obj,
    
    -- Metadata
    name = "ScreenDimmer",
    version = "1.9",
    author = "Ville Walveranta",
    license = "MIT",
    
    -- Configuration
    config = {
        -- Number of seconds of user inactivity before screens dim
        idleTimeout = 300,  -- 5 minutes (call can override)

        -- Target brightness level as percentage of maximum brightness
        -- e.g., 10 means dim to 10% of maximum brightness, regardless
        -- of the original level (call can override)
        -- dimPercentage = 10,

        -- Target brightness level as percentage of maximum brightness
        dimPercentage = {
            internal = 10,  -- dim internal display to 10%
            external = 0    -- dim external displays to 0%
        },

        -- Enable/disable debug logging output (call can override)
        logging = true,

        -- Duration in seconds for the fade animation when dimming/brightening
        fadeDuration = 0.5,

        fadeSteps = {
            -- Number of steps for internal display brightness transitions
            -- Higher values = smoother animation but more CPU usage
            internal = 20,

            -- Number of steps for external display brightness transitions
            -- Lower value for DDC displays due to their slower response time
            external = 5
        },

        -- How often (in seconds) to check system state for idle timeout
        checkInterval = 10,

        -- Minimum time (in seconds) between processing unlock events
        -- This happens BEFORE systemRedimPeriod delay
        -- Prevents rapid-fire unlock events from queueing up multiple brightness adjustments
        unlockDebounceInterval = 0.5,

        -- Grace period (in seconds) after system unlock to allow macOS 
        -- to complete its own brightness restoration operations;
        -- Must be LESS than unlockGracePeriod below
        systemRedimPeriod = 1.5,

        -- Time window (in seconds) after unlock during which our brightness
        -- restore operations are allowed to run. This should be longer than
        -- systemRedimPeriod to ensure we can adjust brightness after macOS
        -- has finished its operations
        unlockGracePeriod = 5.0
    },
    
    -- State variables
    state = {
        originalBrightness = {},
        isDimmed = false,
        isFading = false,
        isEnabled = false,
        isInitialized = false,
        isRestoring = false,
        isUnlocking = false,
        lastSystemBrightnessCheck = 0,
        dimmedBeforeSleep = false,
        dimmedBeforeLock = false,
        lockState = false,
        lastWakeTime = 0,
        lastUserAction = 0,
        lastUnlockTime = 0,
        lastUnlockEventTime = 0,
        unlockTimer = nil
    }
}

-- Logging function
local function log(message, force)
    if force or obj.config.logging then
        print(os.date("%Y-%m-%d %H:%M:%S: ") .. message)
    end
end

-- Start the ScreenDimmer
function obj:start(showAlert)
    if self.state.isEnabled then
        return self
    end

    log("Starting ScreenDimmer", true)
    self.state.isEnabled = true

    -- Start all watchers
    if self.stateChecker then
        self.stateChecker:start()
    end
    if self.userActionWatcher then
        self.userActionWatcher:start()
    end
    if self.caffeineWatcher then
        self.caffeineWatcher:start()
    end

    -- Reset state
    self:resetState()
    self.state.lastUserAction = hs.timer.secondsSinceEpoch()

    if showAlert ~= false then
        hs.alert.show("Screen Dimmer Started")
    end

    return self
end

-- Stop the ScreenDimmer
function obj:stop(showAlert)
    if not self.state.isEnabled then
        return self
    end

    log("Stopping ScreenDimmer", true)
    self.state.isEnabled = false

    -- Stop all watchers
    if self.stateChecker then
        self.stateChecker:stop()
    end
    if self.userActionWatcher then
        self.userActionWatcher:stop()
    end
    if self.caffeineWatcher then
        self.caffeineWatcher:stop()
    end

    -- Restore brightness if dimmed
    if self.state.isDimmed then
        self:restoreBrightness()
    end

    -- Reset state
    self:resetState()

    if showAlert ~= false then
        hs.alert.show("Screen Dimmer Stopped")
    end

    return self
end

-- Toggle the ScreenDimmer
function obj:toggle()
    if self.state.isEnabled then
        self:stop()
    else
        self:start()
    end
end

-- Toggle between dimmed and normal brightness states
function obj:toggleDim()
    if self.state.isDimmed then
        self:restoreBrightness()
    else
        self:dimScreens()
    end
end

-- Bind hotkeys
function obj:bindHotkeys(mapping)
    local spec = {
        toggle = function() self:toggle() end,
        dim = function() self:toggleDim() end
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
    if self.state.isInitialized then
        return self
    end

    log("Initializing ScreenDimmer", true)
    if not self:verifyM1DDC() then
        log("WARNING: m1ddc verification failed!", true)
    end
    log("idleTimeout: " .. self.config.idleTimeout, true)
    
    -- Modified logging for dimPercentage
    if type(self.config.dimPercentage) == "table" then
        log(string.format("dimPercentage: internal=%d%%, external=%d%%", 
            self.config.dimPercentage.internal,
            self.config.dimPercentage.external), true)
    else
        log("dimPercentage: " .. tostring(self.config.dimPercentage), true)
    end
    
    log("logging: " .. tostring(self.config.logging), true)

    self.state.lastWakeTime = hs.timer.secondsSinceEpoch()
    self.state.lastUserAction = self.state.lastWakeTime
    self.state.lastUnlockTime = self.state.lastWakeTime

    -- Detect DDC-capable screens
    self:detectDDCCapableScreens()

    -- Initialize isDimmed based on current screen brightness
    local screens = self:getAllScreens()
    local allDimmed = true
    for _, screen in ipairs(screens) do
        local brightness = self:getBrightness(screen)
        local dimThreshold = self:getDimLevel(screen)
        if brightness and brightness > dimThreshold then
            allDimmed = false
            break
        end
    end
    self.state.isDimmed = allDimmed
    if self.state.isDimmed then
        log("Initialization detected already dimmed screens")
    else
        log("Initialization detected normal brightness screens")
    end

    self.stateChecker = hs.timer.new(self.config.checkInterval, function() self:checkAndUpdateState() end)

    -- In the eventtap watcher
    self.userActionWatcher = hs.eventtap.new({
        hs.eventtap.event.types.keyDown,
        hs.eventtap.event.types.leftMouseDown,
        hs.eventtap.event.types.rightMouseDown,
        hs.eventtap.event.types.mouseMoved,
        hs.eventtap.event.types.flagsChanged,
        hs.eventtap.event.types.scrollWheel
    }, function(event)
        if self.state.lockState or self.state.isUnlocking then
            return false
        end

        local now = hs.timer.secondsSinceEpoch()
        
        -- Only update if significant time has passed
        if (now - self.state.lastUserAction) > 0.1 then
            self.state.lastUserAction = now
            -- log(string.format("Significant user action detected at %.1f", now))
        end

        if self.state.isDimmed then
            log("User action while dimmed, restoring brightness")
            self:restoreBrightness()
        end
        return false
    end)

    self.caffeineWatcher = hs.caffeinate.watcher.new(function(eventType)
        self:caffeineWatcherCallback(eventType)
    end)

    hs.alert.show("Screen Dimmer Initialized")
    self:start(false)

    self.state.isInitialized = true
    return self
end

-- Caffeine watcher callback
function obj:caffeineWatcherCallback(eventType)
    log("Caffeinate event: " .. eventType, true)
    local now = hs.timer.secondsSinceEpoch()

    if eventType == hs.caffeinate.watcher.screensDidLock then
        self.state.lockState = true
        if self.state.isDimmed then
            self.state.dimmedBeforeLock = true
            log("Locked while dimmed")
        end

    elseif eventType == hs.caffeinate.watcher.screensDidUnlock then
        if (now - self.state.lastUnlockEventTime) < self.config.unlockDebounceInterval then
            log("Ignoring extra unlock event within debounce interval")
            return
        end
        
        log("Processing unlock event")
        self.state.lastUnlockEventTime = now
        self.state.lockState = false
        
        -- Stop timers
        if self.stateChecker then self.stateChecker:stop() end
        if self.state.unlockTimer then self.state.unlockTimer:stop() end
        
        -- Set initial timing trackers
        self.state.lastUnlockTime = now
        self.state.lastUserAction = now
        
        -- Create a staged unlock sequence
        log("Starting staged unlock sequence")
        
        -- Stage 1: Wait for macOS brightness restore
        hs.timer.doAfter(self.config.systemRedimPeriod, function()
            log("Stage 1: Delayed brightness restore starting")
            if self.state.isDimmed then
                log("Restoring brightness after system settle")
                self:restoreBrightness()
            end
            
            -- Stage 2: Grace period and state reset
            hs.timer.doAfter(self.config.unlockGracePeriod, function()
                log("Stage 2: Post-unlock grace period completed")
                
                -- Double check brightness values
                local screens = self:getAllScreens()
                for _, screen in ipairs(screens) do
                    local currentBrightness = self:getBrightness(screen)
                    log(string.format("Screen '%s' brightness check: %.2f", 
                        screen:name(), currentBrightness or -1))
                end
                
                -- Reset timing trackers
                local currentTime = hs.timer.secondsSinceEpoch()
                self.state.lastUserAction = currentTime
                self.state.lastUnlockTime = currentTime
                
                -- Stage 3: Resume normal operation
                log("Stage 3: Resuming normal operation")
                if self.stateChecker then
                    self.stateChecker:start()
                end
            end)
        end)

    elseif eventType == hs.caffeinate.watcher.systemDidWake then
        self.state.lastWakeTime = now
        self.state.lastUserAction = now
        if self.stateChecker then self.stateChecker:stop() end

        hs.timer.doAfter(1, function()
            if self.state.dimmedBeforeSleep then
                log("Woke from sleep, was dimmed, restoring brightness")
                self:restoreBrightness()
            end
            self:resetState()

            hs.timer.doAfter(self.config.unlockGracePeriod, function()
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
        log(".. with overriding values.", true)
        if config.idleTimeout ~= nil then
            self.config.idleTimeout = config.idleTimeout
        end
        if config.dimPercentage ~= nil then
            -- Handle both table and number formats
            if type(config.dimPercentage) == "table" then
                self.config.dimPercentage = {
                    internal = config.dimPercentage.internal or 10,
                    external = config.dimPercentage.external or 0
                }
            else
                -- Convert single value to table format
                self.config.dimPercentage = {
                    internal = config.dimPercentage,
                    external = config.dimPercentage
                }
            end
        end
        if config.logging ~= nil then
            self.config.logging = config.logging
        end

        log("Configuration now:", true)
        log(string.format("  - idleTimeout: %s", tostring(self.config.idleTimeout)), true)
        log(string.format("  - dimPercentage internal: %s", tostring(self.config.dimPercentage.internal)), true)
        log(string.format("  - dimPercentage external: %s", tostring(self.config.dimPercentage.external)), true)
        log(string.format("  - logging: %s", tostring(self.config.logging)), true)
    end
    return self
end

-- Get all screens
function obj:getAllScreens()
    return hs.screen.allScreens()
end

-- FadeScreens function with proper fadeTimer scope
function obj:fadeScreens(screens, fromBrightnessTable, toBrightnessTable, callback)
    if self.state.isFading then
        log("fadeScreens called while already fading, waiting to complete")
        -- Optional: Queue the fade request or return
        return
    end
    self.state.isFading = true
    log("Fading screens from original brightness to target brightness", true)
    
    -- Configuration for step counts and durations
    local config = {
        externalSteps = self.config.fadeSteps.external,
        internalSteps = self.config.fadeSteps.internal,
        fadeDuration = self.config.fadeDuration
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
        self.state.isFading = false
        if callback then callback() end
        return
    end
    
    -- Local function to handle group completion
    local function onGroupComplete()
        completedGroups = completedGroups + 1
        if completedGroups >= totalGroups then
            self.state.isFading = false
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
    if self.state.isDimmed or not self.state.isEnabled then
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
    self.state.originalBrightness = {}
    local validScreens = {}
    local fromBrightnessTable = {}
    local toBrightnessTable = {}

    -- First pass: collect current brightness values
    for _, screen in ipairs(screens) do
        local id = screen:id()
        local currentBrightness = self:getBrightness(screen)
        local dimThreshold = self:getDimLevel(screen)  -- Get threshold for this specific screen
        
        -- Only dim screens that are actually brighter than our dim threshold
        if currentBrightness and currentBrightness > dimThreshold then
            log(string.format("Screen '%s' (ID: %d) will be dimmed from %.2f to %.2f", 
                screen:name(), id, currentBrightness, dimThreshold))
            
            self.state.originalBrightness[id] = currentBrightness
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
        self.state.isDimmed = true  -- Mark as dimmed since all screens are already at or below threshold
        return
    end

    self:fadeScreens(validScreens, fromBrightnessTable, toBrightnessTable, function()
        self.state.isDimmed = true
        self.state.dimmedBeforeSleep = true
        log("Screens dimmed", true)
    end)
end

-- Restore brightness function
function obj:restoreBrightness()
    if self.state.lockState then
        log("Skipping brightness restore while system is locked")
        return
    end

    if self.state.isRestoring then
        log("restoreBrightness called while already restoring, ignoring")
        return
    end

    log("restoreBrightness called", true)

    if next(self.state.originalBrightness) == nil then
        log("No original brightness values stored, cannot restore")
        -- Reset states even if we can't restore
        self.state.isDimmed = false
        self.state.dimmedBeforeLock = false
        self.state.dimmedBeforeSleep = false
        self.state.isRestoring = false
        return
    end

    self.state.isRestoring = true
    local screens = self:getAllScreens()
    local restorations = {}

    -- Collect screens that have stored brightness values
    for _, screen in ipairs(screens) do
        local id = screen:id()
        if self.state.originalBrightness[id] ~= nil then
            local currentBrightness = self:getBrightness(screen)
            restorations[id] = {
                screen = screen,
                from = currentBrightness or self.state.originalBrightness[id],
                to = self.state.originalBrightness[id]
            }
            log(string.format("Preparing to restore brightness for screen '%s' (ID: %d): from %.2f to %.2f", 
                screen:name(), id, restorations[id].from, restorations[id].to))
        else
            log(string.format("Skipping screen '%s' (ID: %d) during restore, no original brightness stored", 
                screen:name(), id))
        end
    end

    if next(restorations) == nil then
        log("No screens to restore")
        -- Reset states even if no screens need restoration
        self.state.isDimmed = false
        self.state.dimmedBeforeLock = false
        self.state.dimmedBeforeSleep = false
        self.state.isRestoring = false
        self.state.originalBrightness = {}
        return
    end

    -- First pass: collect current brightness values
    for _, screen in ipairs(screens) do
        local id = screen:id()
        local currentBrightness = self:getBrightness(screen)
        
        -- Only dim screens that are actually brighter than our dim threshold
        if currentBrightness and currentBrightness > dimThreshold then
            log(string.format("Screen '%s' (ID: %d) will be dimmed from %.2f to %.2f", 
                screen:name(), id, currentBrightness, dimThreshold))
            
            self.state.originalBrightness[id] = currentBrightness
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
        self.state.isDimmed = true  -- Mark as dimmed since all screens are already at or below threshold
        return
    end

    self:fadeScreens(validScreens, fromBrightnessTable, toBrightnessTable, function()
        self.state.isDimmed = true
        self.state.dimmedBeforeSleep = true
        log("Screens dimmed", true)
    end)
end

-- Restore brightness function
function obj:restoreBrightness()
    if self.state.lockState then
        log("Skipping brightness restore while system is locked")
        return
    end

    if self.state.isRestoring then
        log("restoreBrightness called while already restoring, ignoring")
        return
    end

    log("restoreBrightness called", true)

    if next(self.state.originalBrightness) == nil then
        log("No original brightness values stored, cannot restore")
        -- Reset states even if we can't restore
        self.state.isDimmed = false
        self.state.dimmedBeforeLock = false
        self.state.dimmedBeforeSleep = false
        self.state.isRestoring = false
        return
    end

    self.state.isRestoring = true
    local screens = self:getAllScreens()
    local restorations = {}

    -- Collect screens that have stored brightness values
    for _, screen in ipairs(screens) do
        local id = screen:id()
        if self.state.originalBrightness[id] ~= nil then
            local currentBrightness = self:getBrightness(screen)
            restorations[id] = {
                screen = screen,
                from = currentBrightness or self.state.originalBrightness[id],
                to = self.state.originalBrightness[id]
            }
            log(string.format("Preparing to restore brightness for screen '%s' (ID: %d): from %.2f to %.2f", 
                screen:name(), id, restorations[id].from, restorations[id].to))
        else
            log(string.format("Skipping screen '%s' (ID: %d) during restore, no original brightness stored", 
                screen:name(), id))
        end
    end

    if next(restorations) == nil then
        log("No screens to restore")
        -- Reset states even if no screens need restoration
        self.state.isDimmed = false
        self.state.dimmedBeforeLock = false
        self.state.dimmedBeforeSleep = false
        self.state.isRestoring = false
        self.state.originalBrightness = {}
        return
    end

    -- Prepare fade tables
    local validScreens = {}
    local fromBrightnessTable = {}
    local toBrightnessTable = {}
    
    for id, restoration in pairs(restorations) do
        table.insert(validScreens, restoration.screen)
        fromBrightnessTable[id] = restoration.from
        toBrightnessTable[id] = restoration.to
    end

    self:fadeScreens(validScreens, fromBrightnessTable, toBrightnessTable, function()
        -- Reset all state variables
        self.state.isDimmed = false
        self.state.dimmedBeforeLock = false
        self.state.dimmedBeforeSleep = false
        self.state.isRestoring = false
        self.state.originalBrightness = {}
        log("Brightness restored", true)
    end)
end

-- Reset state function
function obj:resetState()
    self.state.isDimmed = false
    self.state.isFading = false
    self.state.isRestoring = false
    self.state.isUnlocking = false
    self.state.dimmedBeforeSleep = false
    self.state.dimmedBeforeLock = false
    self.state.originalBrightness = {}
end

-- Get brightness function
function obj:getBrightness(screen)
    local id = screen:id()
    
    -- Check if this is a DDC-capable external screen
    if self.ddcScreens[id] then
        local cmd = string.format("/opt/homebrew/bin/m1ddc get luminance -d %d", id)
        local output, status = hs.execute(cmd)
        if status then
            local brightness = tonumber(output)
            if brightness then
                return brightness / 100  -- Convert percentage to decimal
            end
        end
        log(string.format("Failed to get DDC brightness for screen '%s' (ID: %d)", screen:name(), id))
        return nil
    else
        -- For internal screens, use hs.screen brightness
        return screen:getBrightness()
    end
end

-- Set brightness function
function obj:setBrightness(screen, brightness)
    local id = screen:id()
    
    -- Check if this is a DDC-capable external screen
    if self.ddcScreens[id] then
        local percentage = math.floor(brightness * 100)
        local cmd = string.format("/opt/homebrew/bin/m1ddc set luminance %d -d %d", percentage, id)
        local _, status = hs.execute(cmd)
        if not status then
            log(string.format("Failed to set DDC brightness for screen '%s' (ID: %d)", screen:name(), id))
        end
    else
        -- For internal screens, use hs.screen brightness
        screen:setBrightness(brightness)
    end
end

-- Get appropriate dim level for a screen
function obj:getDimLevel(screen)
    if type(self.config.dimPercentage) == "table" then
        if screen:name():match("Retina") or screen:name():match("Built-in") then
            return self.config.dimPercentage.internal / 100
        else
            return self.config.dimPercentage.external / 100
        end
    end
    -- Fallback to single value if not configured as table
    return (type(self.config.dimPercentage) == "number" and self.config.dimPercentage or 10) / 100
end

-- Check and update state function
function obj:checkAndUpdateState()
    if not self.state.isEnabled then
        return
    end

    if self.state.lockState or self.state.isFading or self.state.isUnlocking then
        log("Skipping state check due to lock/fade/unlock state")
        return
    end

    local now = hs.timer.secondsSinceEpoch()
    local idleTime = now - self.state.lastUserAction

    log(string.format("Current idle time: %.1f seconds (timeout: %d)", idleTime, self.config.idleTimeout))

    if idleTime >= self.config.idleTimeout then
        if not self.state.isDimmed then
            log(string.format("System idle for %.1f seconds, dimming screens", idleTime))
            self:dimScreens()
        end
    end
end

return obj
