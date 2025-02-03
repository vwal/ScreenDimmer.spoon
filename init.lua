local obj = {
    __index = obj,
    
    -- Metadata
    name = "ScreenDimmer",
    version = "5.8",
    author = "Ville Walveranta",
    license = "MIT",
    
    -- Cache the display mappings and priorities
    displayMappings = nil,
    cachedPrioritizedScreens = nil,
    lastPriorityConfig = nil,

    lastScreenConfig = nil,
    lastScreenConfigTime = 0,

    -- Configuration
    config = {
        -- Number of seconds of user inactivity before screens dim
        idleTimeout = 300,  -- 5 minutes

        -- Target brightness level (-100 to 100)
        -- Negative values use subzero (gamma mode)
        -- Positive values use regular (hardware) brightness
        dimLevel = 10,

        -- The default path for Lunar CLI command
        lunarPath = "~/.local/bin/lunar",

        -- Enable/disable expanded debug logging output
        logging = false,

        -- How often (in seconds) to check system state for idle timeout
        checkInterval = 5,

        -- Minimum time (in seconds) between processing unlock events
        unlockDebounceInterval = 0.5,

        -- Optional dimming/undimmg priorities for specific displays
        displayPriorities = {},
        -- Example:
        -- displayPriorities = {
        --     ["Built-in"] = 1,
        --     ["BenQ PD3225U"] = 2,
        --     ["LG Ultra HD"] = 3
        -- }
        -- Default priority for displays not specified in displayPriorities
        defaultDisplayPriority = 999,

        -- Cache-related settings
        screenCacheTimeout = 1.0,    -- How long to cache screen configurations
        priorityCacheEnabled = true, -- Enable/disable priority caching
        displayCacheEnabled = true,  -- Enable/disable display name caching
        
        -- Debug options
        cacheDebugEnabled = false    -- Additional cache-related logging
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
    -- Return cached mappings if enabled and available
    if self.config.displayCacheEnabled and self.displayMappings then
        if self.config.cacheDebugEnabled then
            log("Returning cached display mappings:")
            for k, v in pairs(self.displayMappings) do
                log(string.format("  Cached mapping: %s -> %s", k, v))
            end
        end
        return self.displayMappings
    end
   
    local command = string.format("%s displays", self.lunarPath)
    log("Executing Lunar command: " .. command)
    local output, status = hs.execute(command)
    
    if not status then
        log("Failed to get display list from Lunar", true)
        return {}
    end

    log("Raw Lunar output:\n" .. output)

    local displays = {}
    local currentDisplay = nil
    local currentEDIDName = nil
    
    for line in output:gmatch("[^\r\n]+") do
        -- Match the display header line (e.g., "0: Built-in")
        local num, name = line:match("^(%d+):%s+(.+)$")
        -- Or match the EDID Name line
        local edidName = line:match("^%s*EDID Name:%s+(.+)$")
        
        if num and name then
            currentDisplay = name
            currentEDIDName = nil
            -- Add direct mapping
            displays[name] = name
            
            -- Special case for Built-in display
            if name == "Built-in" then
                displays["Built-in Retina Display"] = "Built-in"
            end
            
            log(string.format("Added primary mapping: %s -> %s", name, name))
            
        elseif edidName and currentDisplay then
            currentEDIDName = edidName
            -- Add EDID mapping if different from current display name
            if edidName ~= currentDisplay then
                displays[edidName] = currentDisplay
                log(string.format("Added EDID mapping: %s -> %s", edidName, currentDisplay))
            end
            
            -- Try variations of the name
            local variations = {
                edidName,
                edidName:gsub(" ", ""),  -- Remove spaces
                edidName:gsub("%-", " "), -- Replace hyphens with spaces
                edidName:gsub(" ", "-")   -- Replace spaces with hyphens
            }
            
            for _, variant in ipairs(variations) do
                if variant ~= currentDisplay and variant ~= edidName then
                    displays[variant] = currentDisplay
                    log(string.format("Added variant mapping: %s -> %s", variant, currentDisplay))
                end
            end
        end
    end
    
    -- Cache the mappings only if caching is enabled
    if self.config.displayCacheEnabled then
        self.displayMappings = displays
        if self.config.cacheDebugEnabled then
            log("Cached new display mappings:")
            for k, v in pairs(displays) do
                log(string.format("  New mapping: %s -> %s", k, v))
            end
        end
    end
    
    return displays
end

function obj:getCurrentScreens()
    local now = hs.timer.secondsSinceEpoch()
    
    -- Check if cache is valid
    local cacheValid = self.lastScreenConfig and 
                      (now - self.lastScreenConfigTime) < self.config.screenCacheTimeout

    if cacheValid and #self.lastScreenConfig > 0 then
        if self.config.cacheDebugEnabled then
            log("Screen cache hit - returning " .. #self.lastScreenConfig .. " screens")
        end
        return self.lastScreenConfig
    end

    -- Cache miss or invalid cache
    if self.config.cacheDebugEnabled then
        log("Screen cache miss - refreshing screen list")
    end
    
    self.lastScreenConfig = hs.screen.allScreens()
    self.lastScreenConfigTime = now
    
    if self.config.cacheDebugEnabled then
        log("Cached " .. #self.lastScreenConfig .. " screens")
    end
    
    return self.lastScreenConfig
end

-- Configuration parser
function obj:parseDisplayConfig(config)
    local displays = {}
    
    -- Handle both old and new format
    if config.displays then
        -- New format
        for name, settings in pairs(config.displays) do
            displays[name] = {
                priority = settings.priority or self.config.defaultDisplayPriority,
                dimLevel = settings.dimLevel
            }
        end
    elseif config.displayPriorities then
        -- Old format compatibility
        for name, value in pairs(config.displayPriorities) do
            if type(value) == "number" then
                displays[name] = {
                    priority = value,
                    dimLevel = nil
                }
            elseif type(value) == "table" then
                displays[name] = {
                    priority = value[1] or self.config.defaultDisplayPriority,
                    dimLevel = value[2]
                }
            end
        end
    end
    
    return displays
end

function obj:sortScreensByPriority(screens)
    if not self.config.priorityCacheEnabled then
        return self:sortScreensUncached(screens)
    end

    -- Safety check for screens array
    if not screens or #screens == 0 then
        log("No screens provided to sort", true)
        return screens
    end

    -- Check if cache is valid
    local cacheValid = self.cachedPrioritizedScreens and
                      #self.cachedPrioritizedScreens == #screens and
                      self.lastPriorityConfig == self.config.displays

    if cacheValid then
        if self.config.cacheDebugEnabled then
            log("Using cached priority order for " .. #screens .. " screens")
        end
        return self.cachedPrioritizedScreens
    end

    -- Cache miss - perform sort
    if self.config.cacheDebugEnabled then
        log("Priority cache miss - sorting " .. #screens .. " screens")
    end

    local sortedScreens = self:sortScreensUncached(screens)
    
    -- Cache results
    self.cachedPrioritizedScreens = sortedScreens
    self.lastPriorityConfig = self.config.displays
    
    return sortedScreens
end

-- Helper function to do the actual sorting
function obj:sortScreensUncached(screens)
    if not self.config.displays or not next(self.config.displays) then
        return screens
    end
    
    local prioritizedScreens = {}
    for _, screen in ipairs(screens) do
        table.insert(prioritizedScreens, screen)
    end
    
    table.sort(prioritizedScreens, function(a, b)
        local settingsA = self.config.displays[a:name()] or {}
        local settingsB = self.config.displays[b:name()] or {}
        local priorityA = settingsA.priority or self.config.defaultDisplayPriority
        local priorityB = settingsB.priority or self.config.defaultDisplayPriority
        return priorityA < priorityB
    end)
    
    -- Log the priority order
    if self.config.logging then
        log("Display priority order:")
        for i, screen in ipairs(prioritizedScreens) do
            local settings = self.config.displays[screen:name()] or {}
            local priority = settings.priority or self.config.defaultDisplayPriority
            log(string.format("  %d. %s (priority: %d)", i, screen:name(), priority))
        end
    end
    
    return prioritizedScreens
end

-- Helper method for display configuration
function obj:display(priority, dimLevel)
    return {
        priority = priority,
        dimLevel = dimLevel
    }
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
        failedRestoreAttempts = 0,
        lastLunarRestart = 0,
        screenWatcher = nil,
        unlockTimer = nil
    }

    -- Initialize cache settings if not set
    if self.config.screenCacheTimeout == nil then
        self.config.screenCacheTimeout = 1.0
    end
    if self.config.priorityCacheEnabled == nil then
        self.config.priorityCacheEnabled = true
    end
    if self.config.displayCacheEnabled == nil then
        self.config.displayCacheEnabled = true
    end
    if self.config.cacheDebugEnabled == nil then
        self.config.cacheDebugEnabled = false
    end

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

    if not self.userActionWatcher then
        log("Failed to create eventtap. Please check Accessibility permissions.", true)
    end

    self:watchCaffeinate()

    if self.config.logging then
        log("Basic initialization complete")
    end
    
    return self
end

function obj:handleWakeUnlock(fromSleep)
    log("Starting wake/unlock handling sequence")
    -- Kill any existing Lunar UI processes first
    os.execute("pkill -f 'Lunar'")
    hs.timer.usleep(500000)  -- 500ms wait
    
    -- Reset all displays to normal mode
    local screens = self:getCurrentScreens()
    local lunarDisplays = self:getLunarDisplayNames()
    
    for _, screen in ipairs(screens) do
        local screenName = screen:name()
        local lunarName = lunarDisplays[screenName]
        
        if lunarName then
            local cmd = string.format("%s displays \"%s\" subzero false", 
                self.lunarPath, lunarName)
            self:executeLunarCommand(cmd)
            
            -- Set brightness to a known good value
            cmd = string.format("%s displays \"%s\" brightness 50", 
                self.lunarPath, lunarName)
            self:executeLunarCommand(cmd)
        end
    end
    
    -- Wait a bit longer before allowing dimming
    hs.timer.usleep(1000000)  -- 1s wait
    
    -- Now proceed with normal wake/unlock handling
    log("Wake/unlock sequence complete, proceeding with brightness restore")
    if self.state.isDimmed or self.state.dimmedBeforeSleep then
        self:restoreBrightness()
    end
end

function obj:handleSleep()
    log("Handling sleep event")
    -- Store dim state before sleep
    self.state.dimmedBeforeSleep = self.state.isDimmed
    -- Clear any stuck states
    self.state.restoreInProgress = false
    self.state.isRestoring = false
end

-- Setup caffeinate watcher
function obj:watchCaffeinate()
    if not self.caffeineWatcher then
        self.caffeineWatcher = hs.caffeinate.watcher.new(function(eventType)
            self:caffeineWatcherCallback(eventType)
        end)
    end
    self.caffeineWatcher:start()
end

-- Setup screen watcher
function obj:setupScreenWatcher()
    self.state.lastScreenChangeTime = 0
    self.state.screenChangeDebounceInterval = 1.0  -- 1 second

    self.state.screenWatcher = hs.screen.watcher.new(function()
        self:invalidateCaches()
        if self.state.isWaking then
            log("Skipping dim reapply during wake cooldown")
            return
        end

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
        self:invalidateCaches()
        
        -- Log current screen configuration
        local screens = self:sortScreensByPriority(self:getCurrentScreens())
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
        -- Clear caches when configuration changes
        self:invalidateCaches()

        log(".. with overriding values:")
        -- Apply all configurations except display settings
        for k, v in pairs(config) do
            if k ~= "displays" and k ~= "displayPriorities" then
                self.config[k] = v
            end
        end
        
        -- Parse display configuration
        self.config.displays = self:parseDisplayConfig(config)
    end

    -- Verify lunar CLI path
    if not self.config.lunarPath then
        log("ERROR: Lunar CLI path not configured! Please set config.lunarPath.", true)
        return self
    end

    -- Test lunar command
    local testCmd = string.format("%s --help", self.config.lunarPath)
    local output, status = hs.execute(testCmd)
    if not status then
        log("ERROR: Unable to execute lunar command. Please verify the configured lunar path: " .. self.config.lunarPath, true)
        return self
    end

    -- Store the lunar path
    self.lunarPath = self.config.lunarPath
    if self.config.logging then
        log("Successfully initialized Lunar CLI at: " .. self.lunarPath, true)
    end

    -- Mark as initialized
    self.state.isInitialized = true

    if self.config.logging then
        log("Configuration now:", true)
        for k, v in pairs(self.config) do
            if k ~= "displays" then
                log(string.format("  - %s: %s", k, tostring(v)), true)
            end
        end
        -- Log display configurations separately
        log("Display configurations:", true)
        for name, settings in pairs(self.config.displays or {}) do
            log(string.format("  - %s: priority=%d, dimLevel=%s",
                name,
                settings.priority,
                settings.dimLevel and tostring(settings.dimLevel) or "default"
            ), true)
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
        if not self.userActionWatcher then
            retryCount = retryCount + 1
            if retryCount <= maxRetries then
                log(string.format("Retry %d/%d: Eventtap not available, retrying creation in %d seconds...", 
                    retryCount, maxRetries, retryDelay))
                
                -- Try to recreate the eventtap
                self.userActionWatcher = hs.eventtap.new({
                    hs.eventtap.event.types.keyDown,
                    hs.eventtap.event.types.flagsChanged,
                    hs.eventtap.event.types.leftMouseDown,
                    hs.eventtap.event.types.rightMouseDown,
                    hs.eventtap.event.types.mouseMoved
                }, function(event)
                    -- ... event handling code ...
                end)
                
                hs.timer.doAfter(retryDelay, startWatcher)
            else
                log("Failed to create eventtap after all retries. Please check Accessibility permissions.", true)
                hs.alert.show("⚠️ Failed to start user activity monitoring\nPlease check Accessibility permissions", 5)
            end
        else
            -- If we have a valid eventtap object, start it
            self.userActionWatcher:start()
            log("User activity watcher started successfully")
        end
    end
    
    startWatcher()

    -- Start all other watchers
    if self.stateChecker then
        self.stateChecker:start()
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

-- Get hardware brightness (without subzero/gamma effects)
function obj:getHardwareBrightness(screen)
    local screenName = screen:name()
    local lunarDisplays = self:getLunarDisplayNames()
    local lunarName = lunarDisplays[screenName]
    
    if not lunarName then
        log(string.format("Display '%s' not found in Lunar display list", screenName), true)
        return nil
    end

    -- Only disable subzero if it’s actually negative
    local currentSubzero = self:getSubzeroDimming(screen)
    if currentSubzero and currentSubzero < 0 then
        local cmdDisableSubzero = string.format("%s displays \"%s\" subzero false", 
            self.lunarPath, lunarName)

        if not self:executeLunarCommand(cmdDisableSubzero) then
            log("Failed to disable subzero for hardware brightness read", true)
            return nil
        end
        hs.timer.usleep(200000)  -- short wait only if we toggled subzero
    end

    -- Small delay to let changes take effect
    hs.timer.usleep(200000)  -- 0.2 seconds
    
    -- Now get the actual hardware brightness
    local command = string.format("%s displays \"%s\" brightness --read", 
        self.lunarPath, lunarName)
    
    local success, output = self:executeLunarCommand(command)
    if not success then
        log("Failed to read hardware brightness", true)
        return nil
    end
    
    local brightness = output and output:match("brightness:%s*(%d+)")
    return brightness and tonumber(brightness)
end

-- Set brightness for a screen
function obj:setBrightness(screen, targetValue)
    local screenName = screen:name()
    local lunarDisplays = self:getLunarDisplayNames()
    local lunarName = lunarDisplays[screenName]
    local isInternalDisplay = screenName:match("Built%-in")
    
    if not lunarName then
        log(string.format("Display '%s' not found in Lunar display list", screenName), true)
        return false
    end

    if targetValue < 0 then
        if isInternalDisplay then
            -- Enable adaptive subzero first
            local cmdAdaptive = string.format("%s displays \"%s\" adaptiveSubzero true", 
                self.lunarPath, lunarName)
            self:executeLunarCommand(cmdAdaptive)
            hs.timer.usleep(100000)  -- 100ms wait
            
            -- Then set the target value
            local targetSubzero = (100 + targetValue) / 100
            local cmdSubzero = string.format("%s displays \"%s\" subzeroDimming %.2f", 
                self.lunarPath, lunarName, targetSubzero)
            if not self:executeLunarCommand(cmdSubzero) then
                log("Failed to set subzero dimming", true)
                return false
            end
            
            log(string.format("Set subzero brightness for '%s': %.2f", 
                screenName, targetSubzero))
        else
            -- For external displays, try the same approach
            local cmdAdaptive = string.format("%s displays \"%s\" adaptiveSubzero true", 
                self.lunarPath, lunarName)
            self:executeLunarCommand(cmdAdaptive)
            hs.timer.usleep(100000)  -- 100ms wait
            
            local targetSubzero = (100 + targetValue) / 100
            local cmdSubzero = string.format("%s displays \"%s\" subzeroDimming %.2f", 
                self.lunarPath, lunarName, targetSubzero)
            if not self:executeLunarCommand(cmdSubzero) then
                return false
            end
        end
    
        log(string.format("Set subzero brightness for '%s': %.2f", 
            screenName, (100 + targetValue) / 100))
    else
        -- For positive values, only disable subzero if currently negative
        local currentSubzero = self:getSubzeroDimming(screen)
        if currentSubzero and currentSubzero < 0 then
            local cmdDisableSubzero = string.format("%s displays \"%s\" subzero false", 
                self.lunarPath, lunarName)
            
            if not self:executeLunarCommand(cmdDisableSubzero) then
                log("Failed to disable subzero", true)
                return false
            end
            
            -- Short wait only if we toggled subzero
            hs.timer.usleep(200000)
        end
        
        -- Set brightness
        local cmdBrightness = string.format("%s displays \"%s\" brightness %d", 
            self.lunarPath, lunarName, targetValue)
        
        if not self:executeLunarCommand(cmdBrightness) then
            log("Failed to set brightness", true)
            return false
        end
        
        log(string.format("Set regular brightness for '%s': %d", 
            screenName, targetValue))
    end
    
    return true
end

-- Get current subzero dimming level
function obj:getSubzeroDimming(screen)
    local screenName = screen:name()
    local lunarDisplays = self:getLunarDisplayNames()
    local lunarName = lunarDisplays[screenName]
    
    if not lunarName then
        log(string.format("Display '%s' not found in Lunar display list", screenName), true)
        return nil
    end

    local command = string.format("%s displays \"%s\" subzeroDimming", 
        self.lunarPath, lunarName)
    
    local success, output = self:executeLunarCommand(command)
    if not success then
        log("Failed to read subzero dimming", true)
        return nil
    end

    local dimming = output and output:match("subzeroDimming:%s*([%d%.]+)")
    if dimming then
        local value = tonumber(dimming)
        -- Convert from 0-1 range to our -100-0 range
        return math.floor((value * 100) - 100)
    end
    return nil
end

-- Set subzero dimming level
function obj:setSubzeroDimming(screen, level)
    local screenName = screen:name()
    local lunarDisplays = self:getLunarDisplayNames()
    local lunarName = lunarDisplays[screenName]
    
    if not lunarName then return false end
    
    -- Enable subzero mode
    local cmdEnableSubzero = string.format("%s displays \"%s\" subzero true", 
        self.lunarPath, lunarName)
        
    if not self:executeLunarCommand(cmdEnableSubzero) then
        return false
    end
    
    -- Set dimming level (convert from -100..0 to 0..1 range)
    local dimming = (100 + level) / 100  -- level is negative
    local cmdSetDimming = string.format("%s displays \"%s\" subzeroDimming %.2f", 
        self.lunarPath, lunarName, dimming)
    
    return self:executeLunarCommand(cmdSetDimming)
end

-- Disable subzero dimming
function obj:disableSubzero(screen)
    local screenName = screen:name()
    local lunarDisplays = self:getLunarDisplayNames()
    local lunarName = lunarDisplays[screenName]
    
    if not lunarName then return false end
    
    local cmd = string.format("%s displays \"%s\" subzero false", 
        self.lunarPath, lunarName)
    
    return self:executeLunarCommand(cmd)
end

function obj:invalidateCaches()
    if self.config.cacheDebugEnabled then
        log("Invalidating caches:")
        if self.displayMappings then
            log("- Display mappings: " .. #(self.displayMappings or {}) .. " entries")
        end
        if self.cachedPrioritizedScreens then
            log("- Prioritized screens: " .. #self.cachedPrioritizedScreens .. " screens")
        end
        if self.lastScreenConfig then
            log("- Screen config: " .. #self.lastScreenConfig .. " screens")
        end
    end

    self.displayMappings = nil
    self.cachedPrioritizedScreens = nil
    self.lastPriorityConfig = nil
    self.lastScreenConfig = nil
    self.lastScreenConfigTime = 0
    
    if self.config.logging or self.config.cacheDebugEnabled then
        log("All display caches invalidated")
    end
end

-- Dim screens function
function obj:dimScreens()
    local screens = self:sortScreensByPriority(self:getCurrentScreens())
    if #screens == 0 then
        log("No screens available to dim", true)
        return
    end
    
    if not self:getLunarDisplayNames() then
        log("No Lunar display mappings available", true)
        return
    end

    -- Bail out checks
    if self.state.isDimmed or not self.state.isEnabled then
        log("dimScreens called but already dimmed or not enabled")
        return
    end
    log("dimScreens called")

    -- Show priority order
    log("Display priority order:")
    for i, screen in ipairs(screens) do
        log(string.format("  %d. %s (priority: %d)", 
            i, screen:name(), self.config.displayPriorities[screen:name()] or 999))
    end

    -- Pre-compute final levels and store original states
    local finalLevels = {}
    self.state.originalBrightness = {}
    self.state.originalSubzero = {}

    -- First pass: compute and store states
    for _, screen in ipairs(screens) do
        local screenName = screen:name()
        local lunarName = self:getLunarDisplayNames()[screenName]
        
        if not lunarName then
            log("Cannot find Lunar name for " .. screenName)
            goto continue
        end

        -- Store original state
        local currentSubzero = self:getSubzeroDimming(screen)
        local currentBrightness = self:getHardwareBrightness(screen)
        
        if not currentBrightness then
            log(string.format("Could not get current brightness for %s", screenName))
            goto continue
        end

        -- Calculate final dim level
        local displaySettings = self.config.displays[screenName] or {}
        local finalLevel = displaySettings.dimLevel or self.config.dimLevel

        -- Special handling for 0: treat it as -1 (minimal gamma dimming)
        if finalLevel == 0 then
            finalLevel = -1
        end

        -- Ensure within bounds
        finalLevel = math.max(-100, math.min(100, finalLevel))

        -- Store all computed values
        self.state.originalBrightness[screenName] = currentBrightness
        self.state.originalSubzero[screenName] = currentSubzero
        finalLevels[screenName] = finalLevel

        log(string.format("Stored original for %s => br=%d, subz=%s, target=%d", 
            screenName, currentBrightness, tostring(currentSubzero), finalLevel))

        ::continue::
    end

    -- Second pass: apply dim settings
    for _, screen in ipairs(screens) do
        local screenName = screen:name()
        local finalLevel = finalLevels[screenName]
        
        if not finalLevel then goto continue end

        local currentBrightness = self.state.originalBrightness[screenName]
        
        -- Skip if target is brighter than current
        if finalLevel >= currentBrightness then
            log(string.format("Skipping dim on %s (finalLevel=%d >= current=%d)",
                screenName, finalLevel, currentBrightness))
            goto continue
        end

        -- Apply the dim settings
        if not self:setBrightness(screen, finalLevel) then
            log(string.format("Failed to set brightness for %s", screenName), true)
        end

        ::continue::
    end

    -- Verification pass after delay
    local verificationDelay = self.state.isWaking and 2.0 or 0.5
    if self.state.isWaking then
        log("Using extended verification delay for wake scenario")
    end
    hs.timer.doAfter(verificationDelay, function()
        local verificationsPassed = 0
        local internalDisplayVerified = false
        
        for _, screen in ipairs(screens) do
            local screenName = screen:name()
            local finalLevel = finalLevels[screenName]
            
            if not finalLevel then goto continue end

            local current
            if finalLevel < 0 then
                current = self:getSubzeroDimming(screen)
            else
                current = self:getHardwareBrightness(screen)
            end

            local tolerance = (finalLevel <= 1) and 1 or 5
            
            local function verifyAndLog(attempt)
                if current and math.abs(current - finalLevel) <= tolerance then
                    verificationsPassed = verificationsPassed + 1
                    if screenName:match("Built%-in") then
                        internalDisplayVerified = true
                    end
                    log(string.format("%s verification passed for %s", 
                        attempt, screenName))
                    return true
                end
                return false
            end

            if not verifyAndLog("First") then
                -- For very low brightness, try one more time
                if finalLevel <= 1 then
                    log(string.format(
                        "First verification failed for low brightness, retrying %s", 
                        screenName))
                    
                    -- Retry the brightness setting
                    if not self:setBrightness(screen, finalLevel) then
                        log(string.format("Retry failed for %s", screenName), true)
                    end
                    
                    -- Second verification after delay
                    hs.timer.doAfter(1.0, function()
                        if finalLevel < 0 then
                            current = self:getSubzeroDimming(screen)
                        else
                            current = self:getHardwareBrightness(screen)
                        end
                        
                        if not verifyAndLog("Second") then
                            log(string.format(
                                "Both verifications failed for %s: target=%d, current=%s", 
                                screenName, finalLevel, tostring(current)), true)
                        end
                    end)
                else
                    log(string.format(
                        "Verification failed for %s: target=%d, current=%s", 
                        screenName, finalLevel, tostring(current)), true)
                end
            end

            ::continue::
        end

        -- Update overall state
        if internalDisplayVerified then
            self.state.isDimmed = true
            self.state.dimmedBeforeSleep = true
            self.state.failedRestoreAttempts = 0
            
            if verificationsPassed < #screens then
                log(string.format(
                    "Partial dim success: %d/%d screens (internal verified)", 
                    verificationsPassed, #screens))
            else
                log("All screens dimmed successfully")
            end
        end
    end)
end

-- Restore brightness function
function obj:restoreBrightness()
    -- Force clear if stuck for too long
    local now = hs.timer.secondsSinceEpoch()
    if self.state.restoreInProgress and 
       self.state.lastRestoreStartTime and 
       (now - self.state.lastRestoreStartTime) > 30 then
        log("Force-clearing stuck restore state", true)
        self.state.restoreInProgress = false
    end

    if self.state.restoreInProgress then
        log("Restore already in progress, skipping")
        return
    end
    
    -- Start new restore
    self.state.restoreInProgress = true
    self.state.lastRestoreStartTime = now
    
    -- Set a safety timeout
    hs.timer.doAfter(30, function()
        if self.state.restoreInProgress then
            log("Force-clearing stuck restoreInProgress flag", true)
            self.state.restoreInProgress = false
        end
    end)
    -- Bail out checks
    if self.state.failedRestoreAttempts and self.state.failedRestoreAttempts >= 2 then
        log("Multiple restore attempts failed, performing emergency reset", true)
        self:emergencyReset()
        self.state.failedRestoreAttempts = 0
        return
    end
    
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
    
    local screens = self:sortScreensByPriority(self:getCurrentScreens())
    local totalScreens = #screens
    local completedScreens = 0
    local verificationsPassed = 0
    
    local function finalRestorationComplete()
        log(string.format("Restoration complete: %d/%d screens verified", 
            verificationsPassed, totalScreens))
        
        -- Update state variables
        self.state.isDimmed = false
        self.state.dimmedBeforeLock = false
        self.state.dimmedBeforeSleep = false
        
        -- Only clear original values if fully successful
        if verificationsPassed == totalScreens then
            log("All screens verified successfully, resetting failure counter")
            self.state.failedRestoreAttempts = 0
            self.state.originalBrightness = {}
            self.state.originalSubzero = {}
        else
            log(string.format("Some screens failed verification (%d/%d)",
                verificationsPassed, totalScreens), true)
        end
        
        self.state.isRestoring = false
        self.state.restoreInProgress = false
    end

    local function verifyScreen(screen, targetBrightness)
        local screenName = screen:name()
        local currentBrightness = self:getHardwareBrightness(screen)
        
        log(string.format(
            "Verifying %s => expected=%d, current=%s",
            screenName, targetBrightness, tostring(currentBrightness)
        ))
        
        local tolerance = (targetBrightness <= 1) and 1 or 5
        return currentBrightness and 
               math.abs(currentBrightness - targetBrightness) <= tolerance
    end
        
    local function restoreOneScreen(index)
        if index > totalScreens then
            finalRestorationComplete()
            return
        end
        
        local screen = screens[index]
        local screenName = screen:name()
        local lunarName = self:getLunarDisplayNames()[screenName]
        local originalBrightness = self.state.originalBrightness[screenName]
        local originalSubzero = self.state.originalSubzero[screenName]
        
        -- Skip if missing data
        if not (lunarName and originalBrightness) then
            log(string.format(
                "No stored brightness or missing Lunar name for %s; skipping restore", 
                screenName
            ))
            return restoreOneScreen(index + 1)
        end
        
        log(string.format(
            "Restoring %s => brightness=%d, subzero=%s",
            screenName, originalBrightness, tostring(originalSubzero)
        ))
        
        -- First set the hardware brightness
        local cmdBrightness = string.format(
            "%s displays \"%s\" brightness %d", 
            self.lunarPath, lunarName, originalBrightness
        )
        log("Executing: " .. cmdBrightness)
        
        if not self:executeLunarCommand(cmdBrightness, 2, 0.5) then
            log(string.format("Failed to set brightness for %s", screenName), true)
            self:resetDisplayState(lunarName)
            return restoreOneScreen(index + 1)
        end
        
        -- Short wait for brightness to take effect
        hs.timer.doAfter(0.5, function()
            -- Then handle subzero state
            if originalSubzero and originalSubzero < 0 then
                self:setSubzeroDimming(screen, originalSubzero)
            else
                -- Only disable if currently active
                local currentSubzero = self:getSubzeroDimming(screen)
                if currentSubzero and currentSubzero < 0 then
                    self:disableSubzero(screen)
                end
            end
            
            -- Verify after all changes are complete
            hs.timer.doAfter(1.0, function()
                if verifyScreen(screen, originalBrightness) then
                    verificationsPassed = verificationsPassed + 1
                    log(string.format("Verification passed for %s", screenName))
                else
                    -- For very low brightness, try one more time
                    if originalBrightness <= 1 then
                        log(string.format(
                            "First verification failed for low brightness, retrying %s", 
                            screenName
                        ))
                        
                        -- Retry brightness setting
                        if not self:executeLunarCommand(cmdBrightness, 2, 0.5) then
                            log(string.format("Retry failed to set brightness for %s", screenName), true)
                        end
                        
                        -- Second verification
                        hs.timer.doAfter(1.0, function()
                            if verifyScreen(screen, originalBrightness) then
                                verificationsPassed = verificationsPassed + 1
                                log(string.format("Second verification passed for %s", 
                                    screenName))
                            else
                                log(string.format(
                                    "Both verifications failed for %s", screenName
                                ), true)
                                self.state.failedRestoreAttempts = 
                                    (self.state.failedRestoreAttempts or 0) + 1
                                self:resetDisplayState(lunarName)
                            end
                            completedScreens = completedScreens + 1
                            if completedScreens == totalScreens then
                                finalRestorationComplete()
                            else
                                restoreOneScreen(index + 1)
                            end
                        end)
                        return
                    else
                        -- Regular brightness failure
                        log(string.format(
                            "Verification failed for %s, attempting recovery", 
                            screenName
                        ), true)
                        self.state.failedRestoreAttempts = 
                            (self.state.failedRestoreAttempts or 0) + 1
                        self:resetDisplayState(lunarName)
                    end
                end
                completedScreens = completedScreens + 1
                if completedScreens == totalScreens then
                    finalRestorationComplete()
                else
                    restoreOneScreen(index + 1)
                end
            end)
        end)
    end

    log(string.format("Restoring brightness for %d screens", totalScreens))
    
    -- Start the restore sequence
    restoreOneScreen(1)
end

-- Failsafe to make sure subzero (gamma) is disabled
function obj:resetDisplayState(lunarName)
    log(string.format("Attempting failsafe reset for display: %s", lunarName), true)
    
    -- Define reset commands
    local resetCommands = {
        string.format("%s displays \"%s\" subzero false", self.lunarPath, lunarName),
        string.format("%s displays \"%s\" gamma reset", self.lunarPath, lunarName),
        string.format("%s displays \"%s\" brightness 50", self.lunarPath, lunarName)
    }
    
    -- Execute commands sequentially with delays
    local function executeCommand(index)
        if index > #resetCommands then
            log("Reset sequence completed")
            self.state.failedRestoreAttempts = 0
            return
        end
        
        local cmd = resetCommands[index]
        log("Executing failsafe command: " .. cmd)
        
        -- Use executeLunarCommand with increased retries and delay for reset operations
        if not self:executeLunarCommand(cmd, 3, 1.0) then
            log(string.format("Failsafe command failed: %s", cmd), true)
        end
        
        -- Schedule next command after delay
        hs.timer.doAfter(0.5, function()
            executeCommand(index + 1)
        end)
    end
    
    -- Start executing commands
    executeCommand(1)
end

function obj:emergencyReset()
    local now = hs.timer.secondsSinceEpoch()
    
    -- Prevent restarts more frequent than every 30 seconds
    if (now - self.state.lastLunarRestart) < 30 then
        log("Skipping Lunar restart - too soon since last restart", true)
        hs.alert.show("⚠️ Lunar restart skipped (cooling down)", 2)
        return
    end
    
    log("Performing emergency Lunar reset", true)
    hs.alert.show("🚨 Emergency Lunar reset in progress...", 3)
    
    -- Kill Lunar
    hs.execute("killall Lunar")
    
    -- Update last restart time
    self.state.lastLunarRestart = now
    
    -- Wait and restart
    hs.timer.doAfter(2, function()
        hs.execute("open -a Lunar")
        -- Clear our display cache
        self:invalidateCaches()
        hs.alert.show("🌙 Lunar restarted", 3)
    end)
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
-- In your bindHotkeys function:
function obj:bindHotkeys(mapping)
    local spec = {
        toggle = function() self:toggle() end,
        dim = function() self:toggleDim() end,
        reset = function() 
            -- Force reset all displays
            local lunarDisplays = self:getLunarDisplayNames()
            for _, lunarName in pairs(lunarDisplays) do
                self:resetDisplayState(lunarName)
            end
        end
    }
    hs.spoons.bindHotkeysToSpec(spec, mapping)
end

-- Reset state function
function obj:resetState()
    self.state.isDimmed = false
    self.state.isRestoring = false
    self.state.isUnlocking = false
    self.state.dimmedBeforeLock = false
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
        
        -- Force clear any stuck restore state
        self.state.restoreInProgress = false
        
        -- Stop state checker temporarily
        if self.stateChecker then 
            self.stateChecker:stop() 
        end
        
        -- Reset timing trackers
        self.state.lastUnlockTime = now
        self.state.lastUserAction = now
        
        -- Check both current dim state and wake-from-sleep state
        if self.state.isDimmed or self.state.dimmedBeforeSleep then
            log("Restoring brightness after unlock (dim=" .. 
                tostring(self.state.isDimmed) .. ", beforeSleep=" .. 
                tostring(self.state.dimmedBeforeSleep) .. ")")
            self:restoreBrightness()
        end
        
        -- Resume normal operation after a delay
        hs.timer.doAfter(3, function()
            if self.stateChecker then
                self.stateChecker:start()
            end
        end)    

    elseif eventType == hs.caffeinate.watcher.systemDidWake then
        self:invalidateCaches()
        hs.timer.doAfter(0.5, function()
            -- Pre-warm cache before restoration
            self:getLunarDisplayNames()
            if self.config.logging then
                log("Pre-warmed display cache after wake")
            end
        end)
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

        self.state.isWaking = true
        hs.timer.doAfter(3, function()
            self.state.isWaking = false
        end)

        log("System woke from sleep. Last dim state: " .. tostring(self.state.dimmedBeforeSleep))

        hs.timer.doAfter(5, function()
            if self.stateChecker then
                self.stateChecker:start()
            end
        end)
    end
end

function obj:executeLunarCommand(cmd, maxRetries, timeout)
    maxRetries = maxRetries or (self.state.isWaking and 5 or 2)  -- More retries during wake
    timeout = timeout or (self.state.isWaking and 0.3 or 0.5)    -- Shorter delay during wake
    local retryDelay = timeout or 0.5
    
    local function attempt(retryCount)
        local success, result = pcall(function()
            local output, status = hs.execute(cmd)
            if not status then
                error("Command failed: " .. (output or "unknown error"))
            end
            return output
        end)
        
        if success then
            return true, result
        end
        
        if retryCount < maxRetries then
            log(string.format("Lunar command failed, retry %d/%d: %s", 
                retryCount + 1, maxRetries, cmd))
            hs.timer.doAfter(retryDelay, function()
                return attempt(retryCount + 1)
            end)
        else
            log(string.format("Lunar command failed after %d retries: %s", 
                maxRetries, cmd), true)
            return false, result
        end
    end
    
    return attempt(0)
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
