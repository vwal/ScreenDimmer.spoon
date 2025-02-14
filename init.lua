local obj = {
    __index = obj,
    
    -- Metadata
    name = "ScreenDimmer",
    version = "8.0",
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
        isEnabled = false,
        isInitialized = false,
        isDimmed = false,
        isRestoring = false,
        isWaking = false,
        isHotkeyDimming = false,
        isScreenSaverActive = false,
        lockState = false,
        resetInProgress = false,
        wakeUnlockInProgress = false,
        globalOperationInProgress = false,
        lunarRestartInProgress = false,
    
        -- Brightness states
        originalBrightness = {},
        originalSubzero = {},
        preSleepBrightness = {},
    
        -- Operations
        pendingOperations = {},
        failedRestoreAttempts = 0,
        
        -- Timers/Watchers
        screenWatcher = nil,
        screenChangeDebounce = nil,
        activeTimers = {},
        
        -- Timestamps (consider initializing all with hs.timer.secondsSinceEpoch())
        lastWakeTime = hs.timer.secondsSinceEpoch(),
        lastUserAction = hs.timer.secondsSinceEpoch(),
        lastUnlockTime = hs.timer.secondsSinceEpoch(),
        lastUnlockEventTime = 0,
        lastHotkeyTime = 0,
        lastLunarRestart = 0,
        lastRestoreStartTime = 0,
        lastScreenSaverEvent = hs.timer.secondsSinceEpoch()
    }
}

-- Logging function
local function log(message, force)
    if force or obj.config.logging then
        print(os.date("%Y-%m-%d %H:%M:%S: ") .. message)
    end
end

-- Core timer management functions
function obj:createTimer(delay, callback, description)
    if not self.state.activeTimers then self.state.activeTimers = {} end
    
    -- Create timer reference first
    local timerRef
    
    local wrappedCallback = function()
        -- Remove from active timers before executing
        if timerRef then
            self.state.activeTimers[timerRef] = nil
        end
        
        local ok, err = pcall(function()
            callback(self)
        end)
        
        if not ok then
            log(string.format("Timer error (%s): %s", 
                description or "unnamed", 
                tostring(err)), true)
        end
    end
    
    -- Now create the actual timer
    timerRef = hs.timer.doAfter(delay, wrappedCallback)
    
    -- Store in active timers
    self.state.activeTimers[timerRef] = {
        description = description or "unnamed timer",
        created = hs.timer.secondsSinceEpoch(),
        delay = delay
    }
    
    if self.config.debug then
        log("Created timer: " .. description)
    end
    
    return timerRef
end

function obj:clearTimers(filter)
    if not self.state.activeTimers then return end
    
    local count = 0
    for timer, info in pairs(self.state.activeTimers) do
        if not filter or filter(info) then
            if timer and timer.stop then
                timer:stop()
                self.state.activeTimers[timer] = nil
                count = count + 1
                if self.config.debug then
                    log("Stopped timer: " .. info.description)
                end
            end
        end
    end
    
    if count > 0 and self.config.debug then
        log(string.format("Cleared %d timers", count))
    end
end

function obj:cleanupStaleTimers()
    local now = hs.timer.secondsSinceEpoch()
    self:clearTimers(function(info)
        return (now - info.created) > (info.delay * 2)
    end)
end

function obj:getLunarDisplayNames()
    if self.config.displayCacheEnabled and self.displayMappings then
        return self.displayMappings
    end
   
    local maxRetries = 3
    local retryDelay = 0.5
    
    for attempt = 1, maxRetries do
        local command = string.format("%s displays", self.lunarPath)
        local output, status = hs.execute(command)
        
        if status then
            local displays = {}
            local currentDisplay = nil
            local currentEdid = nil
            local currentSerial = nil
            
            for line in output:gmatch("[^\r\n]+") do
                local num, name = line:match("^(%d+):%s+(.+)$")
                local edid = line:match("^%s*EDID Name:%s+(.+)$")
                local serial = line:match("^%s*Serial:%s+(.+)$")
                
                if num and name then
                    currentDisplay = name
                elseif edid then
                    -- Strip the sequential numbers like (1), (2) from EDID
                    currentEdid = edid:gsub("%s*%([%d]+%)", "")
                elseif serial then
                    currentSerial = serial
                    
                    -- Create display info
                    local info = {
                        name = currentDisplay,
                        edid = currentEdid,
                        serial = currentSerial
                    }
                    
                    -- Store by full name and serial
                    displays[currentDisplay] = info
                    displays[currentSerial] = info
                    
                    -- Handle Built-in display special cases
                    if currentDisplay == "Built-in" then
                        displays["Built-in Retina Display"] = info
                        displays["Built-in"] = info
                    end
                    
                    -- Store base EDID name (without sequence numbers)
                    local baseEdid = currentDisplay:gsub("%s*%([%d]+%)", "")
                    if not displays[baseEdid] then
                        displays[baseEdid] = info
                    end
                    
                    log(string.format("Mapped display: %s (EDID: %s) -> serial: %s", 
                        currentDisplay, currentEdid, currentSerial))
                end
            end
            
            if next(displays) then  -- Check if we got any displays
                if self.config.displayCacheEnabled then
                    self.displayMappings = displays
                end
                return displays
            else
                log(string.format("Got empty display list from Lunar (attempt %d/%d)", 
                    attempt, maxRetries))
            end
        else
            log(string.format("Failed to get display list from Lunar (attempt %d/%d)", 
                attempt, maxRetries))
        end
        
        if attempt < maxRetries then
            log(string.format("Waiting %.1f seconds before retry...", retryDelay))
            hs.timer.usleep(retryDelay * 1000000)
        end
    end
    
    log("All attempts to get Lunar display list failed", true)
    return {}
end
function obj:getLunarDisplayIdentifier(screen)
    local uniqueName = self:getUniqueNameForScreen(screen)
    local displayId = screen:getUUID() or screen:id() or uniqueName
    local lunarDisplays = self:getLunarDisplayNames()
    local displayInfo = nil

    -- First try exact match
    displayInfo = lunarDisplays[displayId] or lunarDisplays[uniqueName]

    -- If not found and it's a UUID, try direct UUID lookup
    if not displayInfo and screen:getUUID() then
        displayInfo = lunarDisplays[screen:getUUID()]
    end

    -- If still not found, try matching without sequence numbers
    if not displayInfo then
        local baseEdid = uniqueName:gsub("%s*%([%d]+%)", "")
        displayInfo = lunarDisplays[baseEdid]
    end

    -- Special case for Built-in display
    if not displayInfo and uniqueName:match("Built%-in") then
        displayInfo = lunarDisplays["Built-in"]
    end

    if not displayInfo then
        log(string.format("No Lunar mapping found for display: %s", uniqueName), true)
        return nil
    end

    -- Return the proper identifier (serial or name)
    return displayInfo.serial or displayInfo.name
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

function obj:getUniqueNameForScreen(screen)
    -- First try to get UUID/serial from screen
    local id = screen:getUUID() or screen:id()
    if id then
        log(string.format("Screen UUID/ID: %s", id))
        -- Check if this ID matches any of our configured UUIDs
        for name, settings in pairs(self.config.displays or {}) do
            log(string.format("Checking against configured display: %s", name))
            if name:match("^%x%x%x%x%x%x%x%x%-") and name == id then
                log(string.format("Found UUID match: %s", id))
                return id
            end
        end
    else
        log("No UUID/ID found for screen")
    end

    -- Fall back to name-based identification
    local base = screen:name()
    log(string.format("Falling back to name-based identification: %s", base))
    local count = 0
    for _, s in ipairs(self:getCurrentScreens()) do
        if s:name() == base then
            count = count + 1
            if s == screen then break end
        end
    end
    if count > 1 then
        local result = base .. " (" .. count .. ")"
        log(string.format("Multiple screens with same name, using: %s", result))
        return result
    else
        log(string.format("Using single screen name: %s", base))
        return base
    end
end

function obj:parseDisplayConfig(config)
    local displays = {}
    
    if config.displays then
        log("Parsing display configuration:")
        -- Build a set of currently connected unique display names and UUIDs
        local currentDisplays = {}
        
        log("Currently connected screens:")
        for _, screen in ipairs(self:getCurrentScreens()) do
            local uniqueName = self:getUniqueNameForScreen(screen)
            local uuid = screen:getUUID() or screen:id()
            
            currentDisplays[uniqueName] = true
            if uuid then
                currentDisplays[uuid] = true
                log(string.format("  - Screen: %s (UUID: %s)", uniqueName, uuid))
            else
                log(string.format("  - Screen: %s", uniqueName))
            end
        end
        
        log("Processing configured displays:")
        for name, settings in pairs(config.displays or {}) do
            log(string.format("  Processing display: %s", name))
            -- Check if it's a UUID pattern
            local isUUID = name:match("^%x%x%x%x%x%x%x%x%-")
            
            if isUUID then
                log(string.format("    Is UUID: %s (connected: %s)", 
                    name, tostring(currentDisplays[name] == true)))
                if currentDisplays[name] then
                    if type(settings) == "table" then
                        local priority = settings.priority or self.config.defaultDisplayPriority
                        log(string.format("    UUID %s: using priority %d", name, priority))
                        displays[name] = {
                            priority = priority,
                            dimLevel = settings.dimLevel
                        }
                    end
                else
                    log(string.format("    UUID %s not found in current displays", name))
                end
            else
                log(string.format("    Is regular name: %s (connected: %s)", 
                    name, tostring(currentDisplays[name] == true)))
                if currentDisplays[name] then
                    if type(settings) == "table" then
                        local priority = settings.priority or self.config.defaultDisplayPriority
                        log(string.format("    %s: using priority %d", name, priority))
                        displays[name] = {
                            priority = priority,
                            dimLevel = settings.dimLevel
                        }
                    end
                else
                    log(string.format("    Display %s not found in current displays", name))
                end
            end
        end
    end
    
    return displays
end

function obj:computeConfigHash(displays)
    if not displays then return "" end
    
    local parts = {}
    local keys = {}
    
    -- Get sorted keys for consistent ordering
    for k in pairs(displays) do
        table.insert(keys, k)
    end
    table.sort(keys)
    
    -- Build hash string
    for _, k in ipairs(keys) do
        local v = displays[k]
        table.insert(parts, string.format("%s:%d:%s",
            k,
            v.priority or 999,
            tostring(v.dimLevel or "default")
        ))
    end
    
    return table.concat(parts, "|")
end

function obj:sortScreensByPriority(screens)
    if not self.config.priorityCacheEnabled then
        return self:sortScreensUncached(screens)
    end

    if self.config.logging then
        log("Current screens and their configured priorities:")
        for _, screen in ipairs(screens) do
            local uniqueName = self:getUniqueNameForScreen(screen)
            local settings = self.config.displays[uniqueName] or {}
            log(string.format("  - %s (configured priority: %s)", 
                uniqueName, 
                tostring(settings.priority or "default")
            ))
        end
    end

    local currentHash = self:computeConfigHash(self.config.displays)
    
    -- Check if cache is valid using hash
    local cacheValid = self.cachedPrioritizedScreens and
                      #self.cachedPrioritizedScreens == #screens and
                      self.lastPriorityConfig == currentHash

    if cacheValid then
        if self.config.logging then
            log("Using cached priority order")
        end
        return self.cachedPrioritizedScreens
    end

    if self.config.logging then
        log("Cache invalid - performing new sort")
    end

    local sortedScreens = self:sortScreensUncached(screens)
    
    -- Store hash when caching
    self.lastPriorityConfig = currentHash
    self.cachedPrioritizedScreens = sortedScreens

    return sortedScreens
end

function obj:sortScreensUncached(screens)
    if not self.config.displays or not next(self.config.displays) then
        return screens
    end
    
    local prioritizedScreens = {}
    for _, screen in ipairs(screens) do
        table.insert(prioritizedScreens, screen)
    end
    
    table.sort(prioritizedScreens, function(a, b)
        local uniqueA = self:getUniqueNameForScreen(a)
        local uniqueB = self:getUniqueNameForScreen(b)
        local settingsA = self.config.displays[uniqueA] or {}
        local settingsB = self.config.displays[uniqueB] or {}
        local priorityA = settingsA.priority or self.config.defaultDisplayPriority
        local priorityB = settingsB.priority or self.config.defaultDisplayPriority
        
        if self.config.logging then
            log(string.format("Comparing %s (priority %d) with %s (priority %d)",
                uniqueA, priorityA, uniqueB, priorityB))
        end
        return priorityA < priorityB
    end)
    
    if self.config.logging then
        log("Priority-sorted screens:")
        for i, screen in ipairs(prioritizedScreens) do
            local uniqueName = self:getUniqueNameForScreen(screen)
            local settings = self.config.displays[uniqueName] or {}
            log(string.format("  %d. %s (priority: %d)", 
                i, uniqueName, settings.priority or self.config.defaultDisplayPriority))
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

    self.state = self.state or {}

    -- Initialize basic state
    self.state = {
        activeTimers = {},
        isInitialized = false,  -- Will be set to true after successful configuration
        isDimmed = false,
        isEnabled = false,
        isRestoring = false,
        lockState = false,
        lunarRestartInProgress = false,
        originalBrightness = {},
        lastWakeTime = hs.timer.secondsSinceEpoch(),
        lastUserAction = hs.timer.secondsSinceEpoch(),
        lastUnlockTime = hs.timer.secondsSinceEpoch(),
        lastUnlockEventTime = 0,
        lastHotkeyTime = 0,
        failedRestoreAttempts = 0,
        lastLunarRestart = 0,
        screenWatcher = nil,
        resetInProgress = false,
        wakeUnlockInProgress = false,
        lastRestoreStartTime = 0,
        screenChangeDebounce = nil,
        isWaking = false,
        originalSubzero = {},
        globalOperationInProgress = false,
        pendingOperations = {},
        preSleepBrightness = {}
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

    -- Verify Lunar health
    self.lunarHealthCheck = hs.timer.new(30, function()
        self:ensureLunarRunning()
    end)
    self.lunarHealthCheck:start()

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
        hs.eventtap.event.types.mouseMoved,
        hs.eventtap.event.types.scrollWheel
    }, function(event)
        if self.state.lockState or self.state.isRestoring then
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

local function waitForInternalDisplay(callback)
    local attempts = 0
    local maxAttempts = 5
    local function check()
        attempts = attempts + 1
        local internal = hs.screen.find("Built%-in")
        if internal or attempts >= maxAttempts then
            if not internal then
                log("Internal display not found after " .. attempts .. " attempts", true)
            end
            callback(internal)
        else
            log("Internal display not found, attempt " .. attempts)
            hs.timer.doAfter(0.5, check)
        end
    end
    check()
end

function obj:validateState()
    local state = self.state
    local valid = true
    
    -- Check for conflicting states
    if state.isDimmed and state.isRestoring then
        log("Invalid state: isDimmed and isRestoring both true", true)
        valid = false
    end
    
    -- Check for stuck states
    local now = hs.timer.secondsSinceEpoch()
    if state.isRestoring and state.lastRestoreStartTime and 
       (now - state.lastRestoreStartTime) > 30 then
        log("Stuck state detected: restore operation too long", true)
        valid = false
    end
    
    -- Check for incomplete state
    if state.isDimmed and 
       (not state.originalBrightness or not next(state.originalBrightness)) then
        log("Invalid state: dimmed but no original brightness stored", true)
        valid = false
    end
    
    if not valid then
        self:resetState()
        return false
    end
    return true
end

function obj:verifyDisplayState(screen, expectedValue, isSubzero)
    local uniqueName = self:getUniqueNameForScreen(screen)
    local maxAttempts = 3
    local attempt = 1
    local verified = false
    
    while attempt <= maxAttempts and not verified do
        local current
        if isSubzero then
            current = self:getSubzeroDimming(screen)
        else
            current = self:getHardwareBrightness(screen)
        end
        
        if not current then
            log(string.format("Failed to get current state for %s (attempt %d/%d)", 
                uniqueName, attempt, maxAttempts))
            attempt = attempt + 1
            hs.timer.usleep(300000)  -- 300ms delay between attempts
            goto continue
        end
        
        local tolerance = isSubzero and 1 or 
                         (uniqueName:match("Built%-in") and 5 or 10)
        
        if math.abs(current - expectedValue) <= tolerance then
            verified = true
            log(string.format("Display state verified for %s: %d (tolerance: %d)", 
                uniqueName, current, tolerance))
            break
        end
        
        log(string.format("Verification failed for %s: expected=%d, got=%d (attempt %d/%d)", 
            uniqueName, expectedValue, current, attempt, maxAttempts))
        
        attempt = attempt + 1
        hs.timer.usleep(500000)  -- 500ms delay between attempts
        
        ::continue::
    end
    
    return verified
end

function obj:handleOperationFailure(operation, screen)
    log(string.format("Operation failed: %s on %s", operation, self:getUniqueNameForScreen(screen)), true)
    
    -- Increment failure counter
    self.state.failedOperations = (self.state.failedOperations or 0) + 1
    
    -- If too many failures, try emergency reset
    if self.state.failedOperations >= 3 then
        log("Too many failed operations, attempting emergency reset", true)
        self:emergencyReset()
        self.state.failedOperations = 0
    end
end

function obj:resetDisplaysAfterWake(fromSleep)
    -- Clear any existing wake/restore timers
    self:clearTimers(function(info)
        return info.description:match("^wake") or info.description:match("^restore")
    end)

    if self.state.globalOperationInProgress then
        log("Global operation in progress, skipping wake reset")
        return
    end
    self.state.globalOperationInProgress = true

    if not self:validateState() then
        log("Invalid state detected during wake, performing emergency reset")
        self:emergencyReset()
        return
    end

    -- Add longer delay for wake from sleep
    if fromSleep then
        log("Wake from sleep detected, adding extra delay")
        self:createTimer(2.0, function(self)
            self:executeWakeReset()
        end, "wake reset delayed")
    else
        self:createTimer(0.5, function(self)
            self:executeWakeReset()
        end, "wake reset immediate")
    end
end

function obj:executeWakeReset()
    -- Clear existing timers/operations
    if self.pendingOperations then
        for _, timer in pairs(self.pendingOperations) do
            timer:stop()
        end
    end
    self.pendingOperations = {}

    -- Check if reset already in progress
    if self.state.resetInProgress then
        log("Display reset already in progress, skipping")
        return
    end
    
    log("Starting display reset sequence")
    
    -- Clear all state flags
    self.state.resetInProgress = true
    self.state.restoreInProgress = false
    self.state.isRestoring = false
    self.state.wakeUnlockInProgress = false
    self.state.isDimmed = false
    
    waitForInternalDisplay(function(internalDisplay)
        local screens = self:getCurrentScreens()
        local processedScreens = {}
        
        -- First disable subzero on all screens
        for _, screen in ipairs(screens) do
            local uniqueName = self:getUniqueNameForScreen(screen)
            local identifier = self:getLunarDisplayIdentifier(screen)
            
            if identifier then
                self:executeLunarCommand(
                    string.format("%s displays \"%s\" subzero false", 
                        self.lunarPath, identifier)
                )
                -- Small delay between subzero commands
                hs.timer.usleep(100000)  -- 100ms
            else
                log(string.format("No Lunar identifier found for %s", uniqueName))
            end
        end
        
        -- Short delay before setting brightness
        hs.timer.usleep(300000)  -- 300ms
        
        -- Then set brightness on all screens
        for _, screen in ipairs(screens) do
            local uniqueName = self:getUniqueNameForScreen(screen)
            local identifier = self:getLunarDisplayIdentifier(screen)
            
            if identifier then
                local targetBrightness = 50
                if self.state.preSleepBrightness and 
                self.state.preSleepBrightness[uniqueName] then
                    targetBrightness = self.state.preSleepBrightness[uniqueName]
                    log(string.format("Restoring pre-sleep brightness for %s: %d", 
                        uniqueName, targetBrightness))
                else
                    log(string.format("No pre-sleep brightness found for %s, using default", 
                        uniqueName))
                end
                
                -- Set brightness
                if self:executeLunarCommand(
                    string.format("%s displays \"%s\" brightness %d", 
                        self.lunarPath, identifier, targetBrightness)
                ) then
                    processedScreens[uniqueName] = targetBrightness
                else
                    log(string.format("Failed to set brightness for %s", uniqueName), true)
                end
                
                -- Small delay between brightness commands
                hs.timer.usleep(200000)  -- 200ms
            else
                log("No Lunar identifier found for " .. uniqueName)
            end
        end

        -- Verify brightness after all screens are processed
        hs.timer.doAfter(1, function()
            local allVerified = true
            for uniqueName, targetBrightness in pairs(processedScreens) do
                local screen = hs.screen.find(uniqueName)
                if screen then
                    local current = self:getHardwareBrightness(screen)
                    if not current or math.abs(current - targetBrightness) > 10 then
                        log(string.format("Brightness verification failed for %s: expected=%d, got=%s",
                            uniqueName, targetBrightness, tostring(current)), true)
                        allVerified = false
                    end
                end
            end
            
            -- Clear operation flags
            self.state.globalOperationInProgress = false
            self.state.resetInProgress = false
            self.state.preSleepBrightness = nil
            
            log(string.format("Wake reset sequence completed (%s)", 
                allVerified and "verified" or "with verification failures"))
        end)
    end)
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
    -- Initialize state
    self.state.lastScreenChangeTime = 0
    self.state.screenChangeDebounceInterval = 1.0
    self.state.screenChangeDebounce = nil

    self.state.screenWatcher = hs.screen.watcher.new(function()
        -- Cancel any pending debounce
        if self.state.screenChangeDebounce then
            self.state.screenChangeDebounce:stop()
        end
        
        -- Create new debounce timer
        self.state.screenChangeDebounce = hs.timer.doAfter(1.0, function()
            self:handleScreenChange()
        end)
    end)
    
    self.state.screenWatcher:start()
    log("Screen watcher initialized and started")
end

function obj:handleScreenChange()
    if self.state.globalOperationInProgress then
        log("Deferring screen configuration change handling")
        hs.timer.doAfter(1.0, function()
            self:handleScreenChange()
        end)
        return
    end

    self:cleanupStaleTimers()

    self:invalidateCaches()
    
    if self.state.isWaking then
        log("Skipping screen change handling during wake cooldown")
        return
    end

    -- Handle internal display first
    local internalDisplay = hs.screen.find("Built%-in")
    if internalDisplay then
        log("Ensuring internal display state during configuration change")
        self:executeLunarCommand(
            string.format("%s displays \"Built-in\" subzero false", self.lunarPath),
            3, 0.5
        )
        
        -- Verify state after short delay
        hs.timer.doAfter(0.5, function()
            local current = self:getHardwareBrightness(internalDisplay)
            if not current or current < 20 then
                log("Internal display needs recovery during config change", true)
                self:resetDisplayState("Built-in")
            end
        end)
    end

    -- Log configuration change
    log("Screen configuration changed", true)
    local screens = self:sortScreensByPriority(self:getCurrentScreens())
    log(string.format("New screen configuration detected: %d display(s)", #screens))
    for _, screen in ipairs(screens) do
        log(string.format("- Display: %s", self:getUniqueNameForScreen(screen)))
    end
    
    -- Reapply dimming if needed
    hs.timer.doAfter(2, function()
        if self.state.isDimmed then
            log("Reapplying dim settings to new screen configuration")
            local wasDimmed = self.state.isDimmed
            self.state.isDimmed = false
            if wasDimmed then
                self:dimScreens()
            end
        end
    end)
end

-- Check and update state function
function obj:checkAndUpdateState()
    if not self.state.isEnabled then
        return
    end

    if self.state.lockState then
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
        
        -- Log the raw display configuration
        log("Raw display configuration:")
        for name, settings in pairs(config.displays or {}) do
            log(string.format("  %s: priority=%s, dimLevel=%s",
                name,
                tostring(settings.priority),
                tostring(settings.dimLevel)
            ))
        end
        
        -- Parse display configuration
        self.config.displays = self:parseDisplayConfig(config)
        
        -- Log the parsed configuration
        log("Parsed display configuration:")
        for name, settings in pairs(self.config.displays or {}) do
            log(string.format("  %s: priority=%s, dimLevel=%s",
                name,
                tostring(settings.priority),
                tostring(settings.dimLevel)
            ))
        end
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
                    if self.state.lockState or self.state.isRestoring then
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

    -- Clear all timers
    self:clearTimers()

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

function obj:getHardwareBrightness(screen)
    local uniqueName = self:getUniqueNameForScreen(screen)
    local displayId = screen:getUUID() or screen:id() or uniqueName
    
    -- Get the Lunar display name/identifier
    local lunarDisplays = self:getLunarDisplayNames()
    local displayInfo = lunarDisplays[displayId] or lunarDisplays[uniqueName]
    
    if not displayInfo then
        -- Try without sequence numbers
        displayInfo = lunarDisplays[uniqueName:gsub("%s*%([%d]+%)", "")]
        -- Try special case for Built-in
        if not displayInfo and uniqueName:match("Built%-in") then
            displayInfo = lunarDisplays["Built-in"]
        end
    end

    if not displayInfo then
        log(string.format("No Lunar mapping found for display: %s", uniqueName))
        return nil
    end

    -- Use the proper identifier (serial or name)
    local identifier = displayInfo.serial or displayInfo.name
    if not identifier then
        log(string.format("No valid identifier found for display: %s", uniqueName))
        return nil
    end

    -- First disable subzero if needed
    local currentSubzero = self:getSubzeroDimming(screen)
    if currentSubzero and currentSubzero < 0 then
        local cmdDisableSubzero = string.format("%s displays \"%s\" subzero false", 
            self.lunarPath, identifier)
        if not self:executeLunarCommand(cmdDisableSubzero) then
            log("Failed to disable subzero")
            return nil
        end
        hs.timer.usleep(200000)  -- 200ms delay
    end

    -- Get hardware brightness
    local command = string.format("%s displays \"%s\" brightness --read", 
        self.lunarPath, identifier)
    
    local success, output = self:executeLunarCommand(command)
    if not success then
        log(string.format("Failed to read brightness for %s", uniqueName))
        return nil
    end
    
    -- Parse brightness from output like "BenQ PD3225U\n\tbrightness: 30"
    local brightness = output:match("brightness:%s*(%d+)")
    if not brightness then
        log(string.format("Could not parse brightness value from output: %s", output))
        return nil
    end
    
    return tonumber(brightness)
end

function obj:setBrightness(screen, targetValue)
    local uniqueName = self:getUniqueNameForScreen(screen)
    local displayId = screen:getUUID() or screen:id() or uniqueName
    local lunarDisplays = self:getLunarDisplayNames()
    local displayInfo = lunarDisplays[displayId] or lunarDisplays[uniqueName]
    
    if not displayInfo then
        -- Try without sequence numbers
        displayInfo = lunarDisplays[uniqueName:gsub("%s*%([%d]+%)", "")]
        -- Try special case for Built-in
        if not displayInfo and uniqueName:match("Built%-in") then
            displayInfo = lunarDisplays["Built-in"]
        end
    end

    if not displayInfo then
        log(string.format("Display '%s' not found in Lunar display list", uniqueName), true)
        return false
    end

    -- Use the proper identifier (serial or name)
    local identifier = displayInfo.serial or displayInfo.name
    if not identifier then
        log(string.format("No valid identifier found for display: %s", uniqueName))
        return false
    end
    
    if targetValue < 0 then
        local cmdAdaptive = string.format("%s displays \"%s\" adaptiveSubzero true", 
            self.lunarPath, identifier)
        if not self:executeLunarCommand(cmdAdaptive) then
            log("Failed to enable adaptive subzero", true)
            return false
        end
        hs.timer.usleep(100000)
        
        local targetSubzero = (100 + targetValue) / 100
        local cmdSubzero = string.format("%s displays \"%s\" subzeroDimming %.2f", 
            self.lunarPath, identifier, targetSubzero)
        if not self:executeLunarCommand(cmdSubzero) then
            log("Failed to set subzero dimming", true)
            return false
        end
    else
        local currentSubzero = self:getSubzeroDimming(screen)
        if currentSubzero and currentSubzero < 0 then
            local cmdDisableSubzero = string.format("%s displays \"%s\" subzero false", 
                self.lunarPath, identifier)
            if not self:executeLunarCommand(cmdDisableSubzero) then
                log("Failed to disable subzero", true)
                return false
            end
            hs.timer.usleep(200000)
        end
        
        local cmdBrightness = string.format("%s displays \"%s\" brightness %d", 
            self.lunarPath, identifier, targetValue)
        if not self:executeLunarCommand(cmdBrightness) then
            log("Failed to set brightness", true)
            return false
        end
    end
    
    log(string.format("Set brightness for '%s' to %d", displayInfo.name, targetValue))
    return true
end

-- Get current subzero dimming level
function obj:getSubzeroDimming(screen)
    local uniqueName = self:getUniqueNameForScreen(screen)
    local displayId = screen:getUUID() or screen:id() or uniqueName
    
    local lunarDisplays = self:getLunarDisplayNames()
    local displayInfo = lunarDisplays[displayId] or lunarDisplays[uniqueName]
    
    if not displayInfo then
        log(string.format("No Lunar mapping found for display: %s", uniqueName))
        return nil
    end

    local identifier = displayInfo.serial or displayInfo.name
    if not identifier then
        log(string.format("No valid identifier found for display: %s", uniqueName))
        return nil
    end

    local command = string.format("%s displays \"%s\" subzeroDimming", 
        self.lunarPath, identifier)
    
    local success, output = self:executeLunarCommand(command)
    if not success then
        log(string.format("Failed to read subzero dimming for %s", uniqueName))
        return nil
    end

    -- Parse subzero value
    local dimming = output:match("subzeroDimming:%s*([%d%.]+)")
    if dimming then
        local value = tonumber(dimming)
        return math.floor((value * 100) - 100)  -- Convert to our scale
    end
    return nil
end

function obj:setSubzeroDimming(screen, level)
    local uniqueName = self:getUniqueNameForScreen(screen)
    local displayId = screen:getUUID() or screen:id() or uniqueName
    local lunarDisplays = self:getLunarDisplayNames()
    local displayInfo = lunarDisplays[displayId] or lunarDisplays[uniqueName]
    
    if not displayInfo then
        -- Try without sequence numbers
        displayInfo = lunarDisplays[uniqueName:gsub("%s*%([%d]+%)", "")]
        -- Try special case for Built-in
        if not displayInfo and uniqueName:match("Built%-in") then
            displayInfo = lunarDisplays["Built-in"]
        end
    end

    if not displayInfo then
        log(string.format("Display '%s' not found in Lunar display list", uniqueName), true)
        return false
    end

    local identifier = displayInfo.serial or displayInfo.name
    if not identifier then
        log(string.format("No valid identifier found for display: %s", uniqueName))
        return false
    end

    -- Enable subzero mode
    local cmdEnableSubzero = string.format("%s displays \"%s\" subzero true",
        self.lunarPath, identifier)
    if not self:executeLunarCommand(cmdEnableSubzero) then
        log("Failed to enable subzero mode", true)
        return false
    end

    hs.timer.usleep(100000)  -- Small delay for mode switch

    -- Set dimming level (convert from -100..0 to 0..1 range)
    local dimming = (100 + level) / 100  -- level is negative
    local cmdSetDimming = string.format("%s displays \"%s\" subzeroDimming %.2f",
        self.lunarPath, identifier, dimming)

    if not self:executeLunarCommand(cmdSetDimming) then
        log("Failed to set subzero dimming level", true)
        return false
    end

    log(string.format("Set subzero dimming for '%s' to %.2f", displayInfo.name, dimming))
    return true
end

-- Disable subzero dimming
function obj:disableSubzero(screen)
    local uniqueName = self:getUniqueNameForScreen(screen)
    local identifier = self:getLunarDisplayIdentifier(screen)
    
    if not identifier then
        log(string.format("No Lunar identifier found for %s", uniqueName))
        return false
    end
    
    local cmd = string.format("%s displays \"%s\" subzero false", 
        self.lunarPath, identifier)
    
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
    if self.state.globalOperationInProgress then
        log("Global operation in progress, skipping dim")
        return
    end

    if not self:validateState() then
        log("Invalid state detected, skipping dim operation")
        return
    end

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
        local uniqueName = self:getUniqueNameForScreen(screen)
        local settings = self.config.displays[uniqueName] or {}
        local priority = settings.priority or self.config.defaultDisplayPriority
        log(string.format("  %d. %s (priority: %d)", i, uniqueName, priority))
    end

    -- Store pre-dim brightness for all screens
    self.state.preSleepBrightness = {}
    for _, screen in ipairs(screens) do
        local uniqueName = self:getUniqueNameForScreen(screen)
        local currentBrightness = self:getHardwareBrightness(screen)
        if currentBrightness then
            self.state.preSleepBrightness[uniqueName] = currentBrightness
            log(string.format("Stored pre-dim brightness for %s: %d", 
                uniqueName, currentBrightness))
        end
    end
    
    -- Pre-compute final levels and store original states
    local finalLevels = {}
    self.state.originalBrightness = {}
    self.state.originalSubzero = {}

    -- First pass: compute and store states
    for _, screen in ipairs(screens) do
        local uniqueName = self:getUniqueNameForScreen(screen)
        local identifier = self:getLunarDisplayIdentifier(screen)
        
        if not identifier then
            log("Cannot find Lunar identifier for " .. uniqueName)
            goto continue
        end

        -- Store original state
        local currentSubzero = self:getSubzeroDimming(screen)
        local currentBrightness = self:getHardwareBrightness(screen)
        
        if not currentBrightness then
            log(string.format("Could not get current brightness for %s", uniqueName))
            goto continue
        end

        -- Calculate final dim level
        local displaySettings = self.config.displays[uniqueName] or {}
        local finalLevel = displaySettings.dimLevel or self.config.dimLevel

        -- Special handling for 0: treat it as -1 (minimal gamma dimming)
        if finalLevel == 0 then
            finalLevel = -1
        end

        -- Ensure within bounds
        finalLevel = math.max(-100, math.min(100, finalLevel))

        -- Store all computed values
        self.state.originalBrightness[uniqueName] = currentBrightness
        self.state.originalSubzero[uniqueName] = currentSubzero
        finalLevels[uniqueName] = finalLevel
        -- Also store the Lunar identifier for later use
        finalLevels[uniqueName .. "_identifier"] = identifier

        log(string.format("Stored original for %s (%s) => br=%d, subz=%s, target=%d", 
            uniqueName, identifier, currentBrightness, tostring(currentSubzero), finalLevel))

        ::continue::
    end

    -- Second pass: apply dim settings
    for _, screen in ipairs(screens) do
        local uniqueName = self:getUniqueNameForScreen(screen)
        local finalLevel = finalLevels[uniqueName]
        
        if not finalLevel then goto continue end

        local currentBrightness = self.state.originalBrightness[uniqueName]
        
        -- Skip if target is brighter than current
        if finalLevel >= currentBrightness then
            log(string.format("Skipping dim on %s (finalLevel=%d >= current=%d)",
                uniqueName, finalLevel, currentBrightness))
            goto continue
        end

        -- Apply the dim settings
        if not self:setBrightness(screen, finalLevel) then
            log(string.format("Failed to set brightness for %s", uniqueName), true)
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
            local uniqueName = self:getUniqueNameForScreen(screen)
            local finalLevel = finalLevels[uniqueName]
            
            if not finalLevel then goto continue end

            -- First verification attempt
            if self:verifyDisplayState(screen, finalLevel, finalLevel < 0) then
                verificationsPassed = verificationsPassed + 1
                if uniqueName:match("Built%-in") then
                    internalDisplayVerified = true
                end
                log(string.format("First verification passed for %s", uniqueName))
            else
                -- For very low brightness, try one more time
                if finalLevel <= 1 then
                    log(string.format(
                        "First verification failed for low brightness, retrying %s", 
                        uniqueName))
                    
                    -- Retry the brightness setting
                    if not self:setBrightness(screen, finalLevel) then
                        log(string.format("Retry failed for %s", uniqueName), true)
                    end
                    
                    -- Second verification after delay
                    hs.timer.doAfter(1.0, function()
                        if self:verifyDisplayState(screen, finalLevel, finalLevel < 0) then
                            verificationsPassed = verificationsPassed + 1
                            if uniqueName:match("Built%-in") then
                                internalDisplayVerified = true
                            end
                            log(string.format("Second verification passed for %s", uniqueName))
                        else
                            log(string.format(
                                "Both verifications failed for %s: target=%d", 
                                uniqueName, finalLevel), true)
                            self:handleOperationFailure("dim", screen)
                        end
                    end)
                else
                    log(string.format(
                        "Verification failed for %s: target=%d", 
                        uniqueName, finalLevel), true)
                    self:handleOperationFailure("dim", screen)
                end
            end

            ::continue::
        end

        -- Update overall state
        if internalDisplayVerified then
            self.state.isDimmed = true
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
    if self.state.globalOperationInProgress then
        log("Global operation in progress, skipping restore")
        return
    end

    if not self:validateState() then
        log("Invalid state detected, skipping restore operation")
        return
    end

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

    -- Get screens in priority order (same as dimming)
    local screens = self:sortScreensByPriority(self:getCurrentScreens())
    
    -- Log the order
    log("Restoration order (same as dim):")
    for i, screen in ipairs(screens) do
        local uniqueName = self:getUniqueNameForScreen(screen)
        local settings = self.config.displays[uniqueName] or {}
        log(string.format("  %d. %s (priority: %d)", 
            i, uniqueName, settings.priority or self.config.defaultDisplayPriority))
    end
    
    local totalScreens = #screens
    log(string.format("Restoring brightness for %d screens (in original priority order)", totalScreens))
    
    -- Start restoration with original order
    self:restoreOneScreen(1, totalScreens, 0, 0, screens)
end

function obj:restoreOneScreen(index, totalScreens, completedScreens, verificationsPassed, screens)
    if index > #screens then
        log("Restore sequence complete")
        self:finalizeRestore(verificationsPassed, totalScreens)
        return
    end

    local screen = screens[index]
    local uniqueName = self:getUniqueNameForScreen(screen)
    local lunarIdentifier = self:getLunarDisplayIdentifier(screen)
    local originalBrightness = self.state.originalBrightness[uniqueName]
    local originalSubzero = self.state.originalSubzero[uniqueName]
    local isInternal = uniqueName:match("Built%-in")
    local retryAttempts = 0
    local maxRetries = isInternal and 1 or 3  -- More retries for external displays
    
    -- Skip if missing data
    if not (lunarIdentifier and originalBrightness) then
        log(string.format(
            "No stored brightness or missing Lunar identifier for %s; skipping restore", 
            uniqueName
        ))
        self:restoreOneScreen(index + 1, totalScreens, completedScreens, verificationsPassed, screens)
        return
    end
    
    local function attemptRestore()
        log(string.format(
            "Restoring %s => brightness=%d, subzero=%s (attempt %d/%d)",
            uniqueName, originalBrightness, tostring(originalSubzero),
            retryAttempts + 1, maxRetries
        ))
        
        -- First disable subzero if needed
        if originalSubzero and originalSubzero < 0 then
            local cmdDisableSubzero = string.format("%s displays \"%s\" subzero false", 
                self.lunarPath, lunarIdentifier)
            if not self:executeLunarCommand(cmdDisableSubzero) then
                log("Failed to disable subzero", true)
                if retryAttempts < maxRetries - 1 then
                    retryAttempts = retryAttempts + 1
                    self:createTimer(0.5, function(self)
                        attemptRestore()
                    end, string.format("restore retry %d for %s", retryAttempts + 1, uniqueName))
                else
                    self:resetDisplayState(lunarIdentifier)
                    self:restoreOneScreen(index + 1, totalScreens, completedScreens + 1, verificationsPassed, screens)
                end
                return
            end
            hs.timer.usleep(300000)  -- 300ms wait after subzero change
        end
        
        -- Then set the hardware brightness
        local cmdBrightness = string.format(
            "%s displays \"%s\" brightness %d", 
            self.lunarPath, lunarIdentifier, originalBrightness
        )
        
        if not self:executeLunarCommand(cmdBrightness) then
            log(string.format("Failed to set brightness for %s", uniqueName), true)
            if retryAttempts < maxRetries - 1 then
                retryAttempts = retryAttempts + 1
                self:createTimer(0.5, function(self)
                    attemptRestore()
                end, string.format("restore retry %d for %s", retryAttempts + 1, uniqueName))
            else
                self:resetDisplayState(lunarIdentifier)
                self:restoreOneScreen(index + 1, totalScreens, completedScreens + 1, verificationsPassed, screens)
            end
            return
        end
        
        self:createTimer(isInternal and 0.3 or 0.8, function(self)
            if self:verifyDisplayState(screen, originalBrightness, false) then
                log(string.format("Verification passed for %s", uniqueName))
                self:restoreOneScreen(index + 1, totalScreens, completedScreens + 1, verificationsPassed + 1, screens)
            else
                if retryAttempts < maxRetries - 1 then
                    retryAttempts = retryAttempts + 1
                    self:createTimer(0.5, function(self)
                        attemptRestore()
                    end, string.format("restore retry %d for %s", retryAttempts + 1, uniqueName))
                else
                    log(string.format("All retries failed for %s", uniqueName), true)
                    self.state.failedRestoreAttempts = (self.state.failedRestoreAttempts or 0) + 1
                    self:handleOperationFailure("restore", screen)
                    self:resetDisplayState(lunarIdentifier)
                    self:restoreOneScreen(index + 1, totalScreens, completedScreens + 1, verificationsPassed, screens)
                end
            end
        end, string.format("verify restore for %s", uniqueName))
    end

    attemptRestore()
end

function obj:finalizeRestore(verificationsPassed, totalScreens)
    log(string.format("Restoration complete: %d/%d screens verified", 
        verificationsPassed, totalScreens))
    
    -- Update state variables
    self.state.isDimmed = false
    self.state.dimmedBeforeLock = false
    
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

-- Failsafe to make sure subzero (gamma) is disabled
function obj:resetDisplayState(lunarName)
    log(string.format("Attempting failsafe reset for display: %s", lunarName), true)
    
    -- Skip gamma reset if it's failing
    local skipGamma = false
    
    -- Define reset commands
    local resetCommands = {
        string.format("%s displays \"%s\" subzero false", self.lunarPath, lunarName),
        string.format("%s displays \"%s\" brightness 50", self.lunarPath, lunarName)
    }
    
    -- Filter out nil commands
    local commands = {}
    for _, cmd in ipairs(resetCommands) do
        if cmd then table.insert(commands, cmd) end
    end
    
    -- Execute commands sequentially with shorter delays
    local function executeCommand(index)
        if index > #commands then
            log("Reset sequence completed")
            self.state.failedRestoreAttempts = 0
            return
        end
        
        local cmd = commands[index]
        log("Executing failsafe command: " .. cmd)
        
        if not self:executeLunarCommand(cmd, 2, 0.3) then
            log(string.format("Failsafe command failed: %s", cmd), true)
            -- Skip to next command
            executeCommand(index + 1)
            return
        end
        
        -- Schedule next command after shorter delay
        hs.timer.doAfter(0.3, function()
            executeCommand(index + 1)
        end)
    end
    
    -- Start executing commands
    executeCommand(1)
end

function obj:ensureLunarRunning()
    -- Check if Lunar is running
    local output = hs.execute("pgrep -x Lunar")
    local now = hs.timer.secondsSinceEpoch()
    
    if output == "" then
        -- Prevent restarts more frequent than every 30 seconds
        if (now - self.state.lastLunarRestart) < 30 then
            log("Skipping Lunar restart - too soon since last restart", true)
            return false
        end
        
        -- Set restart flag
        self.state.lunarRestartInProgress = true
        log("Lunar not running, attempting to restart", true)
        hs.execute("open -a Lunar")
        self.state.lastLunarRestart = now
        
        -- Give it time to start up
        hs.timer.doAfter(5, function()
            self:invalidateCaches()
            -- Only reset displays if we still need to
            if self.state.isDimmed then
                self:resetDisplaysAfterWake(false)
            end
            -- Clear restart flag
            self.state.lunarRestartInProgress = false
        end)
        return false
    end
    
    -- Only do CLI check if we haven't successfully used it recently
    if (now - (self.state.lastSuccessfulCLI or 0)) > 60 then
        -- Test with a simple command
        local testCmd = string.format("%s displays", self.lunarPath)
        local output, status = hs.execute(testCmd)
        
        if status then
            self.state.lastSuccessfulCLI = now
        else
            log("Lunar CLI check failed, but process is running. Waiting for recovery.", true)
            -- Don't trigger emergency reset, just log the issue
        end
    end
    
    return true
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

function obj:resetState()
    self.state.isDimmed = false
    self.state.isRestoring = false
    self.state.dimmedBeforeLock = false
    self.state.isHotkeyDimming = false
    self.state.failedRestoreAttempts = 0
    self.state.originalBrightness = {}
    self.state.originalSubzero = {}
    self.state.preSleepBrightness = {}
end

-- Caffeine watcher callback
function obj:caffeineWatcherCallback(eventType)
    log("Caffeinate event: " .. eventType, true)
    local now = hs.timer.secondsSinceEpoch()

    if eventType == hs.caffeinate.watcher.systemWillSleep then
        log("System preparing for sleep", true)
        -- Clear states immediately
        self.state.restoreInProgress = false
        self.state.isRestoring = false
        self.state.resetInProgress = false
        self.state.wakeUnlockInProgress = false
        -- Stop checker immediately
        if self.stateChecker then
            self.stateChecker:stop()
        end

    elseif eventType == hs.caffeinate.watcher.screensaverDidStart then
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
        
        self:resetDisplaysAfterWake(false)  -- false = not from sleep
        
        -- Keep the state checker management
        if self.stateChecker then 
            self.stateChecker:stop() 
        end
        hs.timer.doAfter(3, function()
            if self.stateChecker then
                self.stateChecker:start()
            end
        end)
    
    elseif eventType == hs.caffeinate.watcher.systemDidWake then
        self:invalidateCaches()
        local now = hs.timer.secondsSinceEpoch()
        self.state.lastWakeTime = now
        self.state.lastUserAction = now
        self.state.isWaking = true
    
        -- Clear dim state
        if self.state.isDimmed then
            log("Clearing dim state from sleep wake")
            self.state.isDimmed = false
            self.state.originalBrightness = {}
            self.state.originalSubzero = {}
        end
    
        -- Stop the checker immediately
        if self.stateChecker then
            self.stateChecker:stop()
        end
    
        -- Always restart Lunar after wake
        log("Restarting Lunar after wake", true)
        hs.execute("killall Lunar")
        self.state.lastLunarRestart = now
        
        -- Wait and restart
        hs.timer.doAfter(2, function()
            hs.execute("open -a Lunar")
            -- Clear our display cache
            self:invalidateCaches()
            
            -- Wait for Lunar to initialize
            hs.timer.doAfter(3, function()
                -- Now perform display reset
                self:resetDisplaysAfterWake(true)
                
                -- Continue with wake sequence
                hs.timer.doAfter(2, function()
                    self.state.isWaking = false
                    self.state.lastUserAction = hs.timer.secondsSinceEpoch()
                    
                    if not self.state.lockState then
                        hs.timer.doAfter(2, function()
                            if self.stateChecker then
                                self.stateChecker:start()
                                self.state.lastUserAction = hs.timer.secondsSinceEpoch()
                            end
                        end)
                    end
                end)
            end)
        end)
        
        log("System woke from sleep.")
    end
end

function obj:executeLunarCommand(cmd, maxRetries, timeout)
    -- Add absolute timeout for commands
    local startTime = hs.timer.secondsSinceEpoch()
    local absoluteTimeout = 5.0  -- 5 seconds max for any command
    
    local function isTimedOut()
        return (hs.timer.secondsSinceEpoch() - startTime) > absoluteTimeout
    end

    maxRetries = maxRetries or (self.state.isWaking and 5 or 2)
    timeout = timeout or (self.state.isWaking and 0.3 or 0.5)

    -- Clean up command if it contains a table reference
    if cmd:match("table: 0x%x+") then
        log("Warning: Command contains table reference, attempting to clean: " .. cmd)
        -- Extract the actual command parts
        local cmdParts = {}
        for part in cmd:gmatch("%S+") do
            if not part:match("^table:") then
                table.insert(cmdParts, part)
            end
        end
        cmd = table.concat(cmdParts, " ")
        log("Cleaned command: " .. cmd)
    end

    local function attempt(retryCount)
        if isTimedOut() then
            log("Command timed out after " .. absoluteTimeout .. " seconds: " .. cmd, true)
            return false
        end

        local success, result = pcall(function()
            local output, status = hs.execute(cmd)
            if not status then
                error("Command failed: " .. (output or "unknown error"))
            end
            return output
        end)
        
        if success then return true, result end
        
        if retryCount < maxRetries and not isTimedOut() then
            log(string.format("Lunar command failed, retry %d/%d: %s", 
                retryCount + 1, maxRetries, cmd))
            hs.timer.usleep(timeout * 1000000)  -- Convert to microseconds
            return attempt(retryCount + 1)
        end
        
        return false, result
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
