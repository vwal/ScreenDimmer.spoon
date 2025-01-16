local obj = {
    __index = obj,
    
    -- Metadata
    name = "ScreenDimmer",
    version = "4.3",
    author = "Ville Walveranta",
    license = "MIT",
    
    -- Cache the display mappings
    displayMappings = nil,

    -- Configuration
    config = {
        -- Number of seconds of user inactivity before screens dim
        idleTimeout = 300,  -- 5 minutes

        -- Target brightness level (-100 to 100)
        -- Negative values use subzero (gamma mode)
        -- Positive values use regular brightness
        dimLevel = 10,

        -- Internal display ± gain level (added to dimLevel)
        internalDisplayGainLevel = 0,  -- No gain by default

        -- The default path for Lunar CLI command
        lunarPath = "~/.local/bin/lunar",

        -- Enable/disable expanded debug logging output
        logging = false,

        -- How often (in seconds) to check system state for idle timeout
        checkInterval = 5,

        -- Minimum time (in seconds) between processing unlock events
        unlockDebounceInterval = 0.5,

        -- Optional dimming/undimmg priorities for specific displays
        displayPriorities = {}
        -- Example:
        -- displayPriorities = {
        --     ["Built-in"] = 1,
        --     ["BenQ PD3225U"] = 2,
        --     ["LG Ultra HD"] = 3
        -- }
    },
    
    -- State variables
    state = {
        originalBrightness = {},
        isDimmed = false,
        isEnabled = false,
        isInitialized = false,
        isRestoring = false,
        isUnlocking = false,
        lockState = false,
        lastWakeTime = 0,
        lastUserAction = 0,
        lastUnlockTime = 0,
        lastUnlockEventTime = 0,
        screenWatcher = nil,
        unlockTimer = nil,
        isHotkeyDimming = false,
        isScreenSaverActive = false,
        inScreenSaverRecovery = false,
        lastScreenSaverEvent = hs.timer.secondsSinceEpoch()
    }
}

-- Logging function
local function log(message, force)
    if force or obj.config.logging then
        print(os.date("%Y-%m-%d %H:%M:%S: ") .. message)
    end
end

function obj:getLunarDisplayNames()
    -- Return cached mappings if available
    if self.displayMappings then
        return self.displayMappings
    end
   
    local command = string.format("%s displays", self.lunarPath)
    local output, status = hs.execute(command)
    
    if not status then
        log("Failed to get display list from Lunar", true)
        return {}
    end

    local displays = {}
    for line in output:gmatch("[^\r\n]+") do
        local num, name = line:match("^(%d+):%s+(.+)$")
        if num and name then
            displays[name] = name  -- Direct mapping
            if name == "Built-in" then
                displays["Built-in Retina Display"] = "Built-in"
            end
            log(string.format("Added display mapping: %s -> %s", name, displays[name]))
        end
    end
    
    -- Cache the mappings
    self.displayMappings = displays
    return displays
end

function obj:sortScreensByPriority(screens)
    -- If no priorities configured, return screens in original order
    if not self.config.displayPriorities or not next(self.config.displayPriorities) then
        return screens
    end
    
    local prioritizedScreens = {}
    for _, screen in ipairs(screens) do
        table.insert(prioritizedScreens, screen)
    end
    
    table.sort(prioritizedScreens, function(a, b)
        local priorityA = self.config.displayPriorities[a:name()] or self.config.defaultDisplayPriority
        local priorityB = self.config.displayPriorities[b:name()] or self.config.defaultDisplayPriority
        return priorityA < priorityB
    end)
    
    return prioritizedScreens
end

-- Get brightness for a screen
function obj:getBrightness(screen)
    local screenName = screen:name()
    local lunarDisplays = self:getLunarDisplayNames()
    local lunarName = lunarDisplays[screenName]
    
    if not lunarName then
        log(string.format("Display '%s' not found in Lunar display list", screenName), true)
        return nil
    end

    local command = string.format("%s displays \"%s\" brightness", self.lunarPath, lunarName)


    local success, output, status = pcall(hs.execute, command)
    if not success then
        log(string.format("Error executing Lunar command: %s", status), true)
        return false
    end

    log(string.format("Raw brightness command output for '%s':", screenName))
    log(output or "nil")
    log("Command status: " .. tostring(status))
    log("Command executed: " .. command)

    if status then
        local brightness = output:match("brightness:%s*(%d+)")
        if brightness then
            local value = tonumber(brightness)
            log(string.format("Parsed brightness value: %d", value))
            return value
        end
    end
    
    log(string.format("Failed to get brightness for screen '%s'", screenName))
    return nil
end

-- Set brightness for a screen
function obj:setBrightness(screen, targetValue)
    local screenName = screen:name()
    local lunarDisplays = self:getLunarDisplayNames()
    local lunarName = lunarDisplays[screenName]
    
    if not lunarName then
        log(string.format("Display '%s' not found in Lunar display list", screenName), true)
        return
    end

    if targetValue < 0 then
        -- For negative values, just set subzero dimming
        local cmd = string.format("%s displays \"%s\" subzeroDimming %.2f", 
            self.lunarPath, lunarName, (100 + targetValue) / 100)

        local success, result = pcall(hs.execute, cmd)
        if not success then
            log(string.format("Error executing Lunar command: %s", result), true)
            return false
        end
        
        log(string.format("Set subzero brightness for '%s': %.2f", 
            screenName, (100 + targetValue) / 100))
    else
        -- For regular brightness, disable subzero and set brightness
        local commands = {
            string.format("%s displays \"%s\" subzero false", 
                self.lunarPath, lunarName),
            string.format("%s displays \"%s\" brightness %d", 
                self.lunarPath, lunarName, targetValue)
        }
        
        for _, cmd in ipairs(commands) do
            local success, result = pcall(hs.execute, cmd)
            if not success then
                log(string.format("Error executing Lunar command: %s", result), true)
                return false
            end
        end
        
        log(string.format("Set regular brightness for '%s': %d", 
            screenName, targetValue))
    end
end

-- Clear the cache when needed
function obj:clearDisplayCache()
    self.displayMappings = nil
end

-- Dim screens function
function obj:dimScreens()
    if self.state.isDimmed or not self.state.isEnabled then
        log("dimScreens called but already dimmed or not enabled")
        return
    end
    
    log("dimScreens called")
    local screens = self:sortScreensByPriority(hs.screen.allScreens())
    if #screens == 0 then
        log("No screens to dim")
        return
    end

    -- Store current brightness levels
    self.state.originalBrightness = {}
    for _, screen in ipairs(screens) do
        local currentBrightness = self:getBrightness(screen)
        if currentBrightness then
            self.state.originalBrightness[screen:name()] = currentBrightness
            
            -- Calculate dim level with gain for internal display
            local dimLevel = self.config.dimLevel
            if screen:name():match("Built%-in") then
                dimLevel = dimLevel + (self.config.internalDisplayGainLevel or 0)
                -- Ensure we stay within valid range
                dimLevel = math.max(-100, math.min(100, dimLevel))
                if self.config.logging then
                    log(string.format("Applying internal display gain: final dim level = %d", dimLevel))
                end
            end
            
            -- Apply dim level (can be negative for subzero mode)
            self:setBrightness(screen, dimLevel)
        end
    end
    
    self.state.isDimmed = true
    self.state.dimmedBeforeSleep = true
    log("Screens dimmed")
end

-- Restore brightness function
function obj:restoreBrightness()
    if self.state.lockState then
        log("Skipping brightness restore while system is locked")
        return
    end

    if not self.state.isDimmed then
        log("Not currently dimmed, ignoring restore request")
        return
    end

    log("restoreBrightness called")
    
    self.state.isRestoring = true
    
    local screens = self:sortScreensByPriority(hs.screen.allScreens())
    for _, screen in ipairs(screens) do
        local screenName = screen:name()
        local lunarDisplays = self:getLunarDisplayNames()
        local lunarName = lunarDisplays[screenName]
        local originalBrightness = self.state.originalBrightness[screenName]
        
        if originalBrightness and lunarName then
            log(string.format("Restoring brightness for '%s' (lunar name: '%s') to %d", 
                screenName, lunarName, originalBrightness))

            -- First set the target brightness while still in subzero mode
            local cmd1 = string.format("%s displays \"%s\" brightness %d", 
                self.lunarPath, lunarName, originalBrightness)
            
            log("Executing: " .. cmd1)
            local success, result = pcall(hs.execute, cmd1)
            if not success then
                log(string.format("Error setting brightness: %s", result), true)
            end

            -- Small delay
            hs.timer.usleep(200000)  -- 0.2 seconds

            -- Then disable subzero mode
            local cmd2 = string.format("%s displays \"%s\" subzero false", 
                self.lunarPath, lunarName)
            
            log("Executing: " .. cmd2)
            success, result = pcall(hs.execute, cmd2)
            if not success then
                log(string.format("Error disabling subzero mode: %s", result), true)
            end

            -- Wait between screens if there are multiple
            hs.timer.usleep(200000)  -- 0.2 seconds
        end
    end

    -- Reset state
    self.state.isDimmed = false
    self.state.dimmedBeforeLock = false
    self.state.dimmedBeforeSleep = false
    self.state.originalBrightness = {}
    
    -- Clear the restoration flag
    hs.timer.doAfter(1, function()
        self.state.isRestoring = false
    end)
    
    log("Brightness restored")
end

-- Initialize ScreenDimmer
function obj:init()
    if self.state.isInitialized then
        if self.config.logging then
            log("Already initialized, returning")
        end
        return self
    end

    if self.config.logging then
        log("Initializing ScreenDimmer", true)
    end

    if not self:checkAccessibility() then
        log("Waiting for accessibility permissions...", true)
        return self
    end

    -- Initialize basic state
    self.state = {
        isInitialized = false,  -- Will be set to true after successful configuration
        isDimmed = false,
        isEnabled = false,
        isRestoring = false,
        isUnlocking = false,
        lockState = false,
        originalBrightness = {},
        lastWakeTime = hs.timer.secondsSinceEpoch(),
        lastUserAction = hs.timer.secondsSinceEpoch(),
        lastUnlockTime = hs.timer.secondsSinceEpoch(),
        lastUnlockEventTime = 0,
        lastHotkeyTime = 0,
        lastRestoreTime = 0,
        screenWatcher = nil,
        unlockTimer = nil
    }

    -- Setup screen watcher
    self:setupScreenWatcher()

    -- Create state checker timer
    self.stateChecker = hs.timer.new(
        self.config.checkInterval, 
        function() self:checkAndUpdateState() end
    )

    -- Setup user activity watcher
    self.userActionWatcher = hs.eventtap.new({
        hs.eventtap.event.types.keyDown,
        hs.eventtap.event.types.flagsChanged,
        hs.eventtap.event.types.leftMouseDown,
        hs.eventtap.event.types.rightMouseDown,
        hs.eventtap.event.types.mouseMoved
    }, function(event)
        if self.state.lockState or self.state.isUnlocking or self.state.isRestoring then
            return false
        end
    
        local now = hs.timer.secondsSinceEpoch()
    
        -- Add safety check for lastScreenSaverEvent
        local screenSaverCooldown = (self.state.lastScreenSaverEvent and 
            (now - self.state.lastScreenSaverEvent) < 3.0)
    
        -- Strict ignore period after hotkey or screen events
        if (now - self.state.lastHotkeyTime) < 2.0 or screenSaverCooldown then
            if self.config.logging then
                log("Ignoring user activity during cooldown period")
            end
            return false
        end
    
        -- Only process events if enough time has passed since last action
        if (now - self.state.lastUserAction) > 0.1 then
            self.state.lastUserAction = now
    
            if self.state.isDimmed and not self.state.isHotkeyDimming then
                if self.config.logging then
                    log("User action while dimmed, restoring brightness")
                end
                self:restoreBrightness()
            end
        end
        
        return false
    end)

    -- Setup caffeine watcher
    self.caffeineWatcher = hs.caffeinate.watcher.new(function(eventType)
        self:caffeineWatcherCallback(eventType)
    end)

    if self.config.logging then
        log("Basic initialization complete")
    end
    
    return self
end

-- Setup screen watcher
function obj:setupScreenWatcher()
    self.state.lastScreenChangeTime = 0
    self.state.screenChangeDebounceInterval = 1.0  -- 1 second

    self.state.screenWatcher = hs.screen.watcher.new(function()
        local now = hs.timer.secondsSinceEpoch()
        
        -- Debounce rapid screen change events
        if (now - self.state.lastScreenChangeTime) < self.state.screenChangeDebounceInterval then
            if self.config.logging then
                log("Debouncing rapid screen configuration change")
            end
            return
        end
        
        self.state.lastScreenChangeTime = now
        log("Screen configuration changed", true)
        
        -- Clear the display mappings cache
        self:clearDisplayCache()
        
        -- Log current screen configuration
        local screens = hs.screen.allScreens()
        log(string.format("New screen configuration detected: %d display(s)", #screens))
        for _, screen in ipairs(screens) do
            log(string.format("- Display: %s", screen:name()))
        end
        
        -- Wait a brief moment for the system to stabilize
        hs.timer.doAfter(2, function()
            -- If screens were dimmed, reapply dimming to all screens
            if self.state.isDimmed then
                log("Reapplying dim settings to new screen configuration")
                -- Store current dim state
                local wasDimmed = self.state.isDimmed
                -- Reset dim state temporarily
                self.state.isDimmed = false
                -- Reapply dimming
                if wasDimmed then
                    self:dimScreens()
                end
            else
                log("Screens were not dimmed, no action needed")
            end
        end)
    end)
    self.state.screenWatcher:start()
    log("Screen watcher initialized and started")
end

-- Check and update state function
function obj:checkAndUpdateState()
    if not self.state.isEnabled then
        return
    end

    if self.state.lockState or self.state.isUnlocking then
        log("Skipping state check due to lock/unlock state")
        return
    end

    local now = hs.timer.secondsSinceEpoch()
    local timeSinceLastAction = now - self.state.lastUserAction

    if self.config.logging then
        log(string.format("timeSinceLastAction = %.1f seconds (timeout: %d)",
                          timeSinceLastAction, self.config.idleTimeout))
    end

    if timeSinceLastAction >= self.config.idleTimeout then
        if not self.state.isDimmed then
            self:dimScreens()
        end
    end
end

-- Configuration function
function obj:configure(config)
    log("Configuring variables...")
    if config then
        log(".. with overriding values:")
        -- Apply all configurations
        for k, v in pairs(config) do
            self.config[k] = v
        end
    end

    -- Verify lunar CLI path
    if not self.config.lunarPath then
        log("ERROR: Lunar CLI path not configured! Please set config.lunarPath.", true)
        return self
    end

    -- Test if lunar command works - using a simple --help command
    local testCmd = string.format("%s --help", self.config.lunarPath)
    local output, status = hs.execute(testCmd)
    if not status then
        log("ERROR: Unable to execute lunar command. Please verify the configured lunar path: " .. self.config.lunarPath, true)
        return self
    end

    -- Store the lunar path for future use
    self.lunarPath = self.config.lunarPath
    if self.config.logging then
        log("Successfully initialized Lunar CLI at: " .. self.lunarPath, true)
    end

    -- Mark as initialized only after successful configuration
    self.state.isInitialized = true

    if self.config.logging then
        log("Configuration now:", true)
        for k, v in pairs(self.config) do
            log(string.format("  - %s: %s", k, tostring(v)), true)
        end
    end

    return self
end

-- Start the ScreenDimmer
function obj:start(showAlert)
    if not self.state.isInitialized then
        log("ERROR: Cannot start ScreenDimmer - not properly initialized", true)
        return self
    end

    if self.state.isEnabled then
        return self
    end

    log("Starting ScreenDimmer", true)
    self.state.isEnabled = true

    -- Try to start the userActionWatcher with retries
    local maxRetries = 3
    local retryDelay = 2 -- seconds
    local retryCount = 0
    
    local function startWatcher()
        if self.userActionWatcher then
            local success = self.userActionWatcher:start()
            if not success then
                retryCount = retryCount + 1
                if retryCount <= maxRetries then
                    log(string.format("Retry %d/%d: Failed to start eventtap, retrying in %d seconds...", 
                        retryCount, maxRetries, retryDelay))
                    hs.timer.doAfter(retryDelay, startWatcher)
                else
                    log("Failed to start eventtap after all retries. Please check Accessibility permissions.", true)
                end
            end
        end
    end
    
    startWatcher()

    -- Start all other watchers
    if self.stateChecker then
        self.stateChecker:start()
    end
    if self.userActionWatcher then
        self.userActionWatcher:start()
    end
    if self.caffeineWatcher then
        self.caffeineWatcher:start()
    end
    if self.state.screenWatcher then
        self.state.screenWatcher:start()
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
    if self.state.screenWatcher then
        self.state.screenWatcher:stop()
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
    local now = hs.timer.secondsSinceEpoch()
    self.state.lastHotkeyTime = now
    
    -- Set flag to indicate dimming was triggered by hotkey
    self.state.isHotkeyDimming = true
    
    -- If we're coming from screensaver, ensure proper state reset
    if self.state.isScreenSaverActive then
        self.state.isScreenSaverActive = false
        self.state.lastUserAction = now
        -- Ensure any existing dimming is cleared
        if self.state.isDimmed then
            self:restoreBrightness()
        end
    end
    
    if self.state.isDimmed then
        self:restoreBrightness()
    else
        self:dimScreens()
    end
    
    -- Clear the hotkey dimming flag after a short delay
    hs.timer.doAfter(2.0, function()
        self.state.isHotkeyDimming = false
    end)
end

-- Bind hotkeys
function obj:bindHotkeys(mapping)
    local spec = {
        toggle = function() self:toggle() end,
        dim = function() self:toggleDim() end
    }
    hs.spoons.bindHotkeysToSpec(spec, mapping)
end

-- Reset state function
function obj:resetState()
    self.state.isDimmed = false
    self.state.isRestoring = false
    self.state.isUnlocking = false
    self.state.dimmedBeforeSleep = false
    self.state.dimmedBeforeLock = false
    self.state.originalBrightness = {}
end

-- Caffeine watcher callback
function obj:caffeineWatcherCallback(eventType)
    log("Caffeinate event: " .. eventType, true)
    local now = hs.timer.secondsSinceEpoch()

    if eventType == hs.caffeinate.watcher.screensaverDidStart then
        log("Screensaver started", true)
        self.state.isScreenSaverActive = true
        self.state.lastScreenSaverEvent = now
        -- Stop the state checker while screensaver is active
        if self.stateChecker then
            self.stateChecker:stop()
        end
        
    elseif eventType == hs.caffeinate.watcher.screensaverDidStop then
        log("Screensaver stopped", true)
        self.state.isScreenSaverActive = false
        self.state.lastScreenSaverEvent = now
        self.state.lastUserAction = now
        
        -- Ensure clean state
        if self.state.isDimmed then
            self:restoreBrightness()
        end
        
        -- Restart the state checker after a delay
        hs.timer.doAfter(3, function()
            if self.stateChecker then
                self.stateChecker:start()
            end
        end)

    elseif eventType == hs.caffeinate.watcher.screensDidLock then
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
        
        -- Stop state checker temporarily
        if self.stateChecker then 
            self.stateChecker:stop() 
        end
        
        -- Reset timing trackers
        self.state.lastUnlockTime = now
        self.state.lastUserAction = now
        
        -- Restore brightness if needed
        if self.state.isDimmed then
            log("Restoring brightness after unlock")
            self:restoreBrightness()
        end
        
        -- Resume normal operation after a delay
        hs.timer.doAfter(3, function()
            if self.stateChecker then
                self.stateChecker:start()
            end
        end)

    elseif eventType == hs.caffeinate.watcher.systemDidWake then
        self.state.lastWakeTime = now
        -- Reset *our* lastUserAction so we do NOT see an immediate idle
        self.state.lastUserAction = now
    
        if not self:checkAccessibility() then
            log("Accessibility permissions lost after wake, attempting recovery...", true)
            return
        end

        if self.stateChecker then
            self.stateChecker:stop()
        end
    
        if self.state.dimmedBeforeSleep then
            log("Woke from sleep, was dimmed, restoring brightness")
            self:restoreBrightness()
        end
        
        self:resetState()
        hs.timer.doAfter(2, function()
            if self.stateChecker then
                self.stateChecker:start()
            end
        end)
    end
end

function obj:checkAccessibility()
    if not hs.accessibilityState() then
        log("Accessibility permissions not granted. Attempting to recover...", true)
        hs.alert.show("⚠️ Hammerspoon needs Accessibility permissions\nPlease check System Settings", 5)
        
        -- Open System Settings to the right page
        hs.execute([[open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]])
        
        -- Set up a watcher to detect when permissions are granted
        local watcherId
        watcherId = hs.accessibilityStateCallback(function()
            if hs.accessibilityState() then
                log("Accessibility permissions granted, reinitializing...", true)
                -- Remove the watcher
                if watcherId then hs.accessibilityStateCallback(watcherId) end
                -- Restart the components that need accessibility
                self:stop(false)
                self:start(false)
            end
        end)
    end
    return hs.accessibilityState()
end

return obj
