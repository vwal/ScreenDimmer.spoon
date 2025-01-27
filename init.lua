local obj = {
    __index = obj,
    
    -- Metadata
    name = "ScreenDimmer",
    version = "4.71",
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
        -- Positive values use regular (hardware) brightness
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
        displayPriorities = {},
        -- Example:
        -- displayPriorities = {
        --     ["Built-in"] = 1,
        --     ["BenQ PD3225U"] = 2,
        --     ["LG Ultra HD"] = 3
        -- }
        -- Default priority for displays not specified in displayPriorities
        defaultDisplayPriority = 999
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
        log("Returning cached display mappings:")
        for k, v in pairs(self.displayMappings) do
            log(string.format("  Cached mapping: %s -> %s", k, v))
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
    
    -- Cache the mappings
    self.displayMappings = displays
    log("Cached new display mappings:")
    for k, v in pairs(displays) do
        log(string.format("  New mapping: %s -> %s", k, v))
    end
    
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
    
    -- Log the priority order if logging is enabled
    if self.config.logging then
        log("Display priority order:")
        for i, screen in ipairs(prioritizedScreens) do
            local priority = self.config.displayPriorities[screen:name()] or self.config.defaultDisplayPriority
            log(string.format("  %d. %s (priority: %d)", i, screen:name(), priority))
        end
    end
    
    return prioritizedScreens
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
        pcall(hs.execute, cmdDisableSubzero)
        hs.timer.usleep(200000)  -- short wait only if we toggled subzero
    end

    -- Small delay to let changes take effect
    hs.timer.usleep(200000)  -- 0.2 seconds
    
    -- Now get the actual hardware brightness
    local command = string.format("%s displays \"%s\" brightness --read", 
        self.lunarPath, lunarName)
    
    local success, output, status = pcall(hs.execute, command)
    if not success or not status then
        log(string.format("Error reading hardware brightness: %s", output), true)
        return nil
    end

    local brightness = output:match("brightness:%s*(%d+)")
    return brightness and tonumber(brightness)
end

-- Set brightness for a screen
function obj:setBrightness(screen, targetValue)
    local screenName = screen:name()
    local lunarDisplays = self:getLunarDisplayNames()
    local lunarName = lunarDisplays[screenName]
    
    if not lunarName then
        log(string.format("Display '%s' not found in Lunar display list", screenName), true)
        return false
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
        -- For positive values, only disable subzero if currently negative
        local currentSubzero = self:getSubzeroDimming(screen)
        if currentSubzero and currentSubzero < 0 then
            local cmdDisableSubzero = string.format("%s displays \"%s\" subzero false", 
                self.lunarPath, lunarName)
            
            local success, result = pcall(hs.execute, cmdDisableSubzero)
            if not success then
                log(string.format("Error disabling subzero: %s", result), true)
                return false
            end
            
            -- Short wait only if we toggled subzero
            hs.timer.usleep(200000)
        end
        
        -- Set brightness
        local cmdBrightness = string.format("%s displays \"%s\" brightness %d", 
            self.lunarPath, lunarName, targetValue)
        
        local success, result = pcall(hs.execute, cmdBrightness)
        if not success then
            log(string.format("Error setting brightness: %s", result), true)
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
    
    local success, output, status = pcall(hs.execute, command)
    if not success or not status then
        log(string.format("Error reading subzero dimming: %s", output), true)
        return nil
    end

    -- The output should be a decimal between 0 and 1
    -- Convert it to our -100 to 0 scale
    local dimming = output:match("subzeroDimming:%s*([%d%.]+)")
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
    pcall(hs.execute, cmdEnableSubzero)
    
    -- Set dimming level (convert from -100..0 to 0..1 range)
    local dimming = (100 + level) / 100  -- level is negative
    local cmdSetDimming = string.format("%s displays \"%s\" subzeroDimming %.2f", 
        self.lunarPath, lunarName, dimming)
    
    local success = pcall(hs.execute, cmdSetDimming)
    return success
end

-- Disable subzero dimming
function obj:disableSubzero(screen)
    local screenName = screen:name()
    local lunarDisplays = self:getLunarDisplayNames()
    local lunarName = lunarDisplays[screenName]
    
    if not lunarName then return false end
    
    local cmd = string.format("%s displays \"%s\" subzero false", 
        self.lunarPath, lunarName)
    return pcall(hs.execute, cmd)
end

-- Clear the cache when needed
function obj:clearDisplayCache()
    self.displayMappings = nil
end

-- Dim screens function
function obj:dimScreens()
    -- Bail out checks
    if self.state.isDimmed or not self.state.isEnabled then
        log("dimScreens called but already dimmed or not enabled")
        return
    end
    log("dimScreens called")

    -- Get and validate screens
    local screens = self:sortScreensByPriority(hs.screen.allScreens())
    if #screens == 0 then
        log("No screens to dim")
        return
    end

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
        local finalLevel = self.config.dimLevel
        if finalLevel == 0 then finalLevel = -1 end
        
        if screenName:match("Built%-in") then
            finalLevel = finalLevel + (self.config.internalDisplayGainLevel or 0)
            finalLevel = math.max(-100, math.min(100, finalLevel))
        end

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
    hs.timer.doAfter(0.5, function()
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
    
    local screens = self:sortScreensByPriority(hs.screen.allScreens())
    local screensToVerify = #screens
    local verificationsPassed = 0
    
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
        if index > #screens then
            -- Finished all screens
            log(string.format("Processed all %d screens during restore", screensToVerify))
            
            -- Update global state
            self.state.isDimmed = false
            self.state.dimmedBeforeLock = false
            self.state.dimmedBeforeSleep = false
            
            if verificationsPassed == screensToVerify then
                log("All screens verified successfully, resetting failure counter")
                self.state.failedRestoreAttempts = 0
                self.state.originalBrightness = {}
                self.state.originalSubzero = {}
            else
                log(string.format("Some screens did not verify (%d/%d)",
                    verificationsPassed, screensToVerify), true)
            end
            
            self.state.isRestoring = false
            log("Brightness restore completed")
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
        
        -- Restore subzero state if needed
        if originalSubzero and originalSubzero < 0 then
            self:setSubzeroDimming(screen, originalSubzero)
        else
            -- Only disable if currently active
            local currentSubzero = self:getSubzeroDimming(screen)
            if currentSubzero and currentSubzero < 0 then
                self:disableSubzero(screen)
            end
        end
        
        -- Wait for subzero changes to take effect
        hs.timer.doAfter(0.3, function()
            -- Set hardware brightness
            local cmdBrightness = string.format(
                "%s displays \"%s\" brightness %d", 
                self.lunarPath, lunarName, originalBrightness
            )
            log("Executing: " .. cmdBrightness)
            
            local success, result = pcall(hs.execute, cmdBrightness)
            if not success then
                log(string.format("Error setting brightness for %s: %s", 
                    screenName, result), true)
                self:resetDisplayState(lunarName)
                return restoreOneScreen(index + 1)
            end
            
            -- Verify after a delay
            hs.timer.doAfter(0.5, function()
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
                        pcall(hs.execute, cmdBrightness)
                        
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
                            restoreOneScreen(index + 1)
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
                restoreOneScreen(index + 1)
            end)
        end)
    end
    
    -- Start the restore sequence
    restoreOneScreen(1)
end

-- Failsafe to make sure subzero (gamma) is disabled
function obj:resetDisplayState(lunarName)
    log(string.format("Attempting failsafe reset for display: %s", lunarName), true)
    
    -- First try the normal reset commands
    local resetCommands = {
        string.format("%s displays \"%s\" subzero false", self.lunarPath, lunarName),
        string.format("%s displays \"%s\" gamma reset", self.lunarPath, lunarName),
        string.format("%s displays \"%s\" brightness 50", self.lunarPath, lunarName)
    }
    
    -- Execute commands sequentially with delays
    local function executeCommand(index)
        if index > #resetCommands then
            self.state.failedRestoreAttempts = 0
            return
        end
        
        local cmd = resetCommands[index]
        log("Executing failsafe command: " .. cmd)
        local success, result = pcall(hs.execute, cmd)
        if not success then
            log(string.format("Failsafe command failed: %s", result), true)
        end
        
        -- Schedule next command after delay
        hs.timer.doAfter(0.2, function()
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
        self:clearDisplayCache()
        hs.alert.show("🌙 Lunar restarted", 3)
    end)
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
