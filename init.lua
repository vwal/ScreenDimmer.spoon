--- === ScreenDimmer ===
---
--- Dims screens after inactivity using smooth gamma fades, with Lunar Pro
--- for state management. Supports deep subzero dimming levels.
--- Each display can be configured individually or by category (internal/external).
---
--- ARCHITECTURE:
---   Hybrid hardware + gamma dimming. First, hardware brightness (DDC/backlight)
---   is reduced to a configurable minimum via Lunar CLI. Then hs.screen:setGamma()
---   provides smooth gamma overlay dimming at ~30fps on ALL displays (including
---   built-in). Lunar CLI is used only for hardware brightness control and
---   adaptiveSubzero management (disabled during dimming, re-enabled on restore).
---
---   Display mapping: hs.screen:getUUID() matches Lunar's display serial
---   (both use CGDisplayCreateUUIDFromDisplayID internally).
---
--- Dim level convention:
---   Positive (1–100): hardware brightness target only
---   Zero: hardware brightness at configured minimum, no gamma/subzero
---   Negative (-1 to -100): hardware brightness at minimum + gamma/subzero
---     Formula: whitepoint = (100 + dimLevel) / 100
---     Examples: -30 → hw min + wp 0.70, -80 → hw min + wp 0.20, -99 → hw min + wp 0.01
---
---   Per-display minBrightness prevents full blackout (default: 2 internal, 1 external)

local obj = {}
obj.__index = obj

-- Spoon metadata
obj.name = "ScreenDimmer"
obj.version = "3.0"
obj.author = ""
obj.license = "MIT"

local log = hs.logger.new("ScreenDimmer", "info")

----------------------------------------------------------------------
-- Configuration defaults
----------------------------------------------------------------------

obj.defaults = {
    idleTimeout      = 300,      -- seconds before dimming
    fadeDuration     = 1.0,      -- seconds for smooth gamma fade
    fadeInterval     = 0.033,    -- ~30fps gamma updates
    checkInterval    = 5,        -- idle-check frequency (seconds)
    lunarPath        = os.getenv("HOME") .. "/.local/bin/lunar",

    -- Category defaults for dim level
    internalDimLevel  = -30,     -- built-in display
    externalDimLevel  = -80,     -- external displays

    -- Minimum hardware brightness (just above zero to prevent blackout)
    internalMinBrightness = 2,   -- built-in: slightly above zero
    externalMinBrightness = 1,   -- externals: near zero

    -- Safety reset: force-restore if stuck in dimming/restoring state
    stuckTimeout      = 30,        -- seconds before force-reset (0 to disable)

    -- Wake sequence
    wakeDelay         = 2,         -- initial delay (seconds) before polling Lunar
    wakePollInterval  = 1,         -- seconds between Lunar readiness checks
    wakePollTimeout   = 15,        -- give up polling after this many seconds

    -- Screensaver cooldown
    screensaverCooldown = 3,       -- seconds to ignore activity after screensaver events

    -- Restore verification
    verifyDelay       = 1,         -- seconds to wait before verifying restore
    verifyRetries     = 2,         -- max retry attempts if brightness mismatch
    verifyTolerance   = 2,         -- acceptable brightness deviation (±)

    -- Lunar health monitoring
    lunarHealthInterval  = 30,     -- seconds between health checks (0 to disable)
    lunarRestartCooldown = 120,    -- minimum seconds between auto-restart attempts
    lunarAppName         = "Lunar",-- app name for 'open -a'

    -- Per-display overrides keyed by Lunar serial (= hs.screen UUID)
    displays          = {},

    logging           = true,    -- TODO: set to false once tuned
}

----------------------------------------------------------------------
-- Instance state
----------------------------------------------------------------------

obj.config            = {}
obj.state             = "idle"   -- idle | dimming | dimmed | restoring
obj.savedState        = {}       -- per-UUID: { brightness, subzero, subzeroDimming, ... }
obj.savedGamma        = {}       -- per-UUID: { whitepoint, blackpoint } from getGamma()
obj.fadeTimer         = nil      -- hs.timer driving the gamma animation
obj.fadeTask          = nil      -- hs.task for Lunar CLI commands
obj.queryTask         = nil      -- hs.task for async display queries
obj.enabled           = false
obj.dimStartTime      = 0        -- for activity cooldown
obj.stateChangeTime   = 0        -- for stuck-state detection
obj.screensaverActive = false    -- screensaver state
obj.lastScreensaverEvent = 0    -- for cooldown after screensaver events
obj.activityTap       = nil
obj.idleCheckTimer    = nil
obj.stuckCheckTimer   = nil
obj.lunarHealthTimer  = nil
obj.lunarHealthTask   = nil      -- hs.task for health check probe
obj.lastLunarRestart  = 0        -- timestamp of last auto-restart
obj.caffeinateWatcher = nil
obj.screenWatcher     = nil
obj.hotkeys           = {}

----------------------------------------------------------------------
-- Logging helpers
----------------------------------------------------------------------

local function logMsg(self, msg, ...)
    if self.config.logging then
        log.i(string.format(msg, ...))
    end
end

local function logAlways(msg, ...)
    log.i(string.format(msg, ...))
end

----------------------------------------------------------------------
-- Lunar CLI helpers (fully async)
----------------------------------------------------------------------

--- Build a shell command string for setting one Lunar property.
function obj:lunarCmd(serial, property, value)
    local v
    if type(value) == "boolean" then
        v = value and "true" or "false"
    elseif type(value) == "number" then
        if property == "brightness" then
            v = tostring(math.floor(value + 0.5))
        else
            v = string.format("%.2f", value)
        end
    else
        v = tostring(value)
    end
    return string.format('%s displays "%s" %s %s', self.config.lunarPath, serial, property, v)
end

--- Run a list of shell commands as a single script (async, non-blocking).
function obj:runLunarScript(cmds, callback)
    if self.fadeTask and self.fadeTask:isRunning() then
        self.fadeTask:terminate()
    end

    if #cmds == 0 then
        if callback then callback(true) end
        return
    end

    local script = table.concat(cmds, "\n")
    logMsg(self, "Lunar script (%d cmds):\n%s", #cmds, script)

    self.fadeTask = hs.task.new("/bin/sh", function(exitCode, stdOut, stdErr)
        self.fadeTask = nil
        if callback then callback(exitCode == 0) end
    end, {"-c", script})
    self.fadeTask:start()
end

--- Query Lunar for all active displays via JSON (ASYNC, non-blocking).
function obj:getDisplaysAsync(callback)
    if self.queryTask and self.queryTask:isRunning() then
        self.queryTask:terminate()
    end

    self.queryTask = hs.task.new(self.config.lunarPath,
        function(exitCode, stdOut, stdErr)
            self.queryTask = nil
            if exitCode ~= 0 or not stdOut or stdOut == "" then
                logAlways("Lunar query failed (exit=%s)", tostring(exitCode))
                callback({})
                return
            end

            local ok, data = pcall(hs.json.decode, stdOut)
            if not ok or not data then
                logAlways("Failed to parse Lunar JSON")
                callback({})
                return
            end

            local result = {}
            for serial, info in pairs(data) do
                if info.active then
                    result[serial] = {
                        name           = info.name or "Unknown",
                        isInternal     = (info.name == "Built-in"),
                        brightness     = info.brightness or 0,
                        subzero        = info.subzero or false,
                        subzeroDimming = info.subzeroDimming or 1,
                    }
                end
            end
            callback(result)
        end,
        {"displays", "-j"})
    self.queryTask:start()
end

--- Resolve the dim level for a display.
function obj:getDimLevel(serial, isInternal)
    local dc = self.config.displays[serial]
    if dc and dc.dimLevel then return dc.dimLevel end
    return isInternal and self.config.internalDimLevel or self.config.externalDimLevel
end

--- Resolve the minimum hardware brightness for a display.
function obj:getMinBrightness(serial, isInternal)
    local dc = self.config.displays[serial]
    if dc and dc.minBrightness then return dc.minBrightness end
    return isInternal and self.config.internalMinBrightness or self.config.externalMinBrightness
end

--- Resolve the priority for a display.
function obj:getDisplayPriority(serial, isInternal)
    local dc = self.config.displays[serial]
    if dc and dc.priority then return dc.priority end
    return isInternal and 100 or 200
end

----------------------------------------------------------------------
-- Smooth gamma fade engine
--
-- Uses hs.screen:setGamma() at ~30fps for buttery smooth transitions.
-- All displays are faded simultaneously — no CLI latency bottleneck.
-- Gamma whitepoint {r,g,b} = uniform value from 1.0 (normal) to target.
----------------------------------------------------------------------

--- Cancel any active fade (timer + Lunar task).
function obj:cancelFade()
    if self.fadeTimer then
        self.fadeTimer:stop()
        self.fadeTimer = nil
    end
    if self.fadeTask then
        if self.fadeTask:isRunning() then
            self.fadeTask:terminate()
        end
        self.fadeTask = nil
    end
    if self.queryTask then
        if self.queryTask:isRunning() then
            self.queryTask:terminate()
        end
        self.queryTask = nil
    end
end

--- Find the hs.screen object for a given UUID.
local function screenForUUID(uuid)
    for _, s in ipairs(hs.screen.allScreens()) do
        if s:getUUID() == uuid then return s end
    end
    return nil
end

--- Run a smooth gamma fade across all displays simultaneously.
---
--- `targets`: list of { uuid, fromWP, toWP }
---   fromWP/toWP are whitepoint values (0.0–1.0).
--- `callback`: called when fade animation completes.
function obj:runGammaFade(targets, callback)
    -- Cancel any active fade
    if self.fadeTimer then
        self.fadeTimer:stop()
        self.fadeTimer = nil
    end

    local duration = self.config.fadeDuration
    local interval = self.config.fadeInterval
    local gamma    = 2.2  -- perceptual correction
    local startTime = hs.timer.secondsSinceEpoch()
    local logging = self.config.logging

    -- Pre-resolve screen objects
    local fadeEntries = {}
    for _, t in ipairs(targets) do
        local screen = screenForUUID(t.uuid)
        if screen then
            -- Perceptual linearization of endpoints
            local from_p = t.fromWP ^ (1 / gamma)
            local to_p   = t.toWP   ^ (1 / gamma)
            table.insert(fadeEntries, {
                screen = screen,
                uuid   = t.uuid,
                from_p = from_p,
                to_p   = to_p,
                toWP   = t.toWP,
            })
        else
            logAlways("No hs.screen for UUID %s — skipping gamma fade", t.uuid)
        end
    end

    if #fadeEntries == 0 then
        logAlways("No screens to fade")
        if callback then callback() end
        return
    end

    if logging then
        local names = {}
        for _, e in ipairs(fadeEntries) do
            table.insert(names, string.format("%s (%.2f→%.2f)",
                e.uuid:sub(1, 4), (e.from_p ^ gamma), e.toWP))
        end
        logAlways("Gamma fade: %s over %.1fs", table.concat(names, ", "), duration)
    end

    self.fadeTimer = hs.timer.doEvery(interval, function()
        local elapsed = hs.timer.secondsSinceEpoch() - startTime
        local progress = math.min(elapsed / duration, 1.0)

        for _, e in ipairs(fadeEntries) do
            -- Interpolate in perceptual space, convert back to raw
            local p_val = e.from_p + (e.to_p - e.from_p) * progress
            local wp = p_val ^ gamma
            e.screen:setGamma(
                { red = wp, green = wp, blue = wp },
                { red = 0,  green = 0,  blue = 0 }
            )
        end

        if progress >= 1.0 then
            self.fadeTimer:stop()
            self.fadeTimer = nil
            if logging then
                logAlways("Gamma fade complete (%.1fs)", elapsed)
            end
            if callback then callback() end
        end
    end)
end

----------------------------------------------------------------------
-- Dim operation
----------------------------------------------------------------------

function obj:dimScreens()
    if self.state == "dimming" or self.state == "dimmed" then return end

    logAlways("Starting dim sequence")
    self.state = "dimming"
    self.dimStartTime = hs.timer.secondsSinceEpoch()
    self.stateChangeTime = self.dimStartTime
    self.savedState = {}
    self.savedGamma = {}

    self:getDisplaysAsync(function(displays)
        if self.state ~= "dimming" then return end

        if not next(displays) then
            logAlways("No displays found — aborting dim")
            self.state = "idle"
            return
        end

        -- Separate displays into:
        --   gammaTargets: external displays using setGamma() for smooth fade
        --   lunarCmds: all Lunar CLI commands (hardware brightness + subzero)
        local gammaTargets = {}
        local lunarCmds = {}

        for serial, d in pairs(displays) do
            local dimLevel = self:getDimLevel(serial, d.isInternal)
            local priority = self:getDisplayPriority(serial, d.isInternal)
            local minBr = self:getMinBrightness(serial, d.isInternal)

            self.savedState[serial] = {
                brightness     = d.brightness,
                subzero        = d.subzero,
                subzeroDimming = d.subzeroDimming,
                isInternal     = d.isInternal,
                name           = d.name,
            }

            local screen = screenForUUID(serial)
            if screen then
                self.savedGamma[serial] = screen:getGamma()
            end

            -- Disable adaptive subzero for all displays during dimming
            table.insert(lunarCmds, self:lunarCmd(serial, "adaptiveSubzero", false))

            if dimLevel > 0 then
                -- Positive dimLevel: hardware brightness only, no gamma/subzero
                logAlways("Dim %s (%s…): brightness %d → %d [priority %d] [hardware]",
                    d.name, serial:sub(1, 8), d.brightness, dimLevel, priority)
                if d.brightness > dimLevel then
                    table.insert(lunarCmds, self:lunarCmd(serial, "brightness", dimLevel))
                end
            else
                -- Zero or negative dimLevel: reduce hardware to minimum, then gamma/subzero
                logAlways("Dim %s (%s…): brightness %d → min %d, level %d [priority %d] [gamma]",
                    d.name, serial:sub(1, 8), d.brightness, minBr, dimLevel, priority)

                -- Reduce hardware brightness to minimum
                if d.brightness > minBr then
                    table.insert(lunarCmds, self:lunarCmd(serial, "brightness", minBr))
                end

                if dimLevel < 0 then
                    -- All displays: smooth gamma fade via setGamma at ~30fps
                    local targetWP = (100 + dimLevel) / 100
                    table.insert(gammaTargets, {
                        uuid   = serial,
                        fromWP = 1.0,
                        toWP   = targetWP,
                    })
                end
                -- dimLevel == 0: hardware minimum only, no gamma/subzero needed
            end
        end

        -- Run Lunar script and gamma fade in parallel
        local pending = 0
        local function onPartDone()
            pending = pending - 1
            if pending == 0 and self.state == "dimming" then
                self.state = "dimmed"
                logAlways("All displays dimmed")
            end
        end

        if #lunarCmds > 0 then
            pending = pending + 1
            self:runLunarScript(lunarCmds, function(ok) onPartDone() end)
        end

        if #gammaTargets > 0 then
            pending = pending + 1
            self:runGammaFade(gammaTargets, function() onPartDone() end)
        end

        if pending == 0 then
            self.state = "dimmed"
            logAlways("Nothing to dim")
        end
    end)
end

----------------------------------------------------------------------
-- Restore operation
----------------------------------------------------------------------

function obj:restoreScreens()
    if self.state ~= "dimmed" and self.state ~= "dimming" then return end

    self:cancelFade()
    self.state = "restoring"
    self.stateChangeTime = hs.timer.secondsSinceEpoch()
    logAlways("Starting restore sequence")

    if not next(self.savedState) then
        logAlways("No saved state to restore from")
        hs.screen.restoreGamma()
        self.state = "idle"
        return
    end

    -- Capture savedState for post-restore verification (before it gets cleared)
    local savedStateForVerify = self.savedState

    -- Phase 1: Restore gamma (visual), then Phase 2: restore hardware brightness
    local gammaTargets = {}
    local brightnessCmds = {}  -- hardware brightness restore (runs after gamma)

    for serial, saved in pairs(self.savedState) do
        local dimLevel = self:getDimLevel(serial, saved.isInternal)

        if dimLevel > 0 then
            -- Was hardware-only dim: just restore brightness
            if saved.brightness ~= dimLevel then
                table.insert(brightnessCmds, self:lunarCmd(serial, "brightness", saved.brightness))
            end
            table.insert(brightnessCmds, self:lunarCmd(serial, "adaptiveSubzero", true))
        else
            -- Was hardware + gamma dim: smooth gamma fade back to 1.0
            if dimLevel < 0 then
                local fromWP = (100 + dimLevel) / 100
                table.insert(gammaTargets, {
                    uuid   = serial,
                    fromWP = fromWP,
                    toWP   = 1.0,
                })
            end

            -- Restore hardware brightness (after gamma/subzero restore)
            local minBr = self:getMinBrightness(serial, saved.isInternal)
            if saved.brightness > minBr then
                table.insert(brightnessCmds, self:lunarCmd(serial, "brightness", saved.brightness))
            end
            table.insert(brightnessCmds, self:lunarCmd(serial, "adaptiveSubzero", true))
        end
    end

    -- Run gamma restore, then hardware brightness restore
    local pending = 0
    local function onGammaDone()
        pending = pending - 1
        if pending == 0 and self.state == "restoring" then
            hs.screen.restoreGamma()
            -- Phase 2: restore hardware brightness
            local function onRestoreComplete(msg)
                self.state = "idle"
                self.savedState = {}
                self.savedGamma = {}
                logAlways(msg)
                self:scheduleVerification(savedStateForVerify)
            end

            if #brightnessCmds > 0 then
                self:runLunarScript(brightnessCmds, function(ok)
                    onRestoreComplete("All displays restored (hardware brightness)")
                end)
            else
                onRestoreComplete("All displays restored")
            end
        end
    end

    if #gammaTargets > 0 then
        pending = pending + 1
        self:runGammaFade(gammaTargets, function() onGammaDone() end)
    end

    if pending == 0 then
        hs.screen.restoreGamma()

        local function onRestoreComplete(msg)
            self.state = "idle"
            self.savedState = {}
            self.savedGamma = {}
            logAlways(msg)
            self:scheduleVerification(savedStateForVerify)
        end

        if #brightnessCmds > 0 then
            self:runLunarScript(brightnessCmds, function(ok)
                onRestoreComplete("All displays restored (hardware brightness)")
            end)
        else
            onRestoreComplete("Nothing to restore")
        end
    end
end

----------------------------------------------------------------------
-- Restore verification
----------------------------------------------------------------------

--- Verify that displays restored to expected brightness, retry if not.
--- `expected`: table of { serial = brightness } to verify against.
--- `attempt`: current attempt number (1-based).
function obj:verifyRestore(expected, attempt)
    if self.state ~= "idle" then return end
    if not expected or not next(expected) then return end

    self:getDisplaysAsync(function(displays)
        if self.state ~= "idle" then return end

        local mismatches = {}
        for serial, expectedBr in pairs(expected) do
            local actual = displays[serial]
            if actual then
                local diff = math.abs(actual.brightness - expectedBr)
                if diff > self.config.verifyTolerance then
                    table.insert(mismatches, {
                        serial     = serial,
                        name       = actual.name,
                        expected   = expectedBr,
                        actual     = actual.brightness,
                    })
                end
            end
        end

        if #mismatches == 0 then
            logAlways("Restore verified: all displays at expected brightness")
            return
        end

        -- Log mismatches
        for _, m in ipairs(mismatches) do
            logAlways("Restore mismatch: %s (%s…) expected %d, got %d",
                m.name, m.serial:sub(1, 8), m.expected, m.actual)
        end

        if attempt >= self.config.verifyRetries then
            logAlways("Restore verification failed after %d attempts", attempt)
            return
        end

        -- Retry: send brightness commands for mismatched displays
        logAlways("Retrying restore for %d display(s) (attempt %d/%d)",
            #mismatches, attempt + 1, self.config.verifyRetries)
        local cmds = {}
        for _, m in ipairs(mismatches) do
            table.insert(cmds, self:lunarCmd(m.serial, "brightness", m.expected))
        end
        self:runLunarScript(cmds, function(ok)
            -- Verify again after delay
            hs.timer.doAfter(self.config.verifyDelay, function()
                self:verifyRestore(expected, attempt + 1)
            end)
        end)
    end)
end

--- Start verification after restore completes.
--- Saves expected brightness from savedState before it's cleared.
function obj:scheduleVerification(savedState)
    if self.config.verifyRetries <= 0 then return end

    local expected = {}
    for serial, saved in pairs(savedState) do
        expected[serial] = saved.brightness
    end
    if not next(expected) then return end

    hs.timer.doAfter(self.config.verifyDelay, function()
        self:verifyRestore(expected, 1)
    end)
end

----------------------------------------------------------------------
-- Stuck-state safety reset
----------------------------------------------------------------------

--- Force-reset everything to a known good state.
function obj:forceReset()
    logAlways("SAFETY RESET: force-restoring from state '%s'", self.state)
    self:cancelFade()
    hs.screen.restoreGamma()

    -- Attempt hardware brightness restore via Lunar
    if next(self.savedState) then
        local cmds = {}
        for serial, saved in pairs(self.savedState) do
            cmds[#cmds + 1] = self:lunarCmd(serial, "brightness", saved.brightness)
            cmds[#cmds + 1] = self:lunarCmd(serial, "adaptiveSubzero", true)
        end
        self:runLunarScript(cmds, nil)
    end

    self.state = "idle"
    self.savedState = {}
    self.savedGamma = {}
    logAlways("Safety reset complete")
end

--- Check if we're stuck in a transient state too long.
function obj:checkStuck()
    if self.config.stuckTimeout <= 0 then return end
    if self.state ~= "dimming" and self.state ~= "restoring" then return end

    local elapsed = hs.timer.secondsSinceEpoch() - self.stateChangeTime
    if elapsed >= self.config.stuckTimeout then
        self:forceReset()
    end
end

----------------------------------------------------------------------
-- Lunar health monitoring
----------------------------------------------------------------------

--- Check if Lunar process is running.
function obj:isLunarRunning()
    local output, status = hs.execute("pgrep -x Lunar")
    return status == true
end

--- Attempt to restart Lunar.
function obj:restartLunar()
    local now = hs.timer.secondsSinceEpoch()
    if now - self.lastLunarRestart < self.config.lunarRestartCooldown then
        logAlways("Lunar restart skipped (cooldown: %.0fs remaining)",
            self.config.lunarRestartCooldown - (now - self.lastLunarRestart))
        return
    end

    self.lastLunarRestart = now
    logAlways("Lunar not healthy — restarting")
    hs.alert.show("ScreenDimmer: restarting Lunar")
    hs.execute(string.format("open -a '%s'", self.config.lunarAppName))
end

--- Run a health check: process alive, then CLI responsive.
function obj:checkLunarHealth()
    if self.config.lunarHealthInterval <= 0 then return end

    -- Step 1: Is the process running?
    if not self:isLunarRunning() then
        logAlways("Lunar health: process not running")
        self:restartLunar()
        return
    end

    -- Step 2: Is the CLI responsive? (async probe)
    if self.lunarHealthTask and self.lunarHealthTask:isRunning() then
        return  -- previous probe still running, skip this cycle
    end

    self.lunarHealthTask = hs.task.new(self.config.lunarPath,
        function(exitCode, stdOut, stdErr)
            self.lunarHealthTask = nil
            if exitCode ~= 0 or not stdOut or stdOut == "" then
                logAlways("Lunar health: CLI unresponsive (exit=%s)", tostring(exitCode))
                -- Process is running but CLI failed — might be hung
                if self:isLunarRunning() then
                    logAlways("Lunar health: process alive but CLI hung — killing and restarting")
                    hs.execute("pkill -x Lunar")
                    hs.timer.doAfter(2, function() self:restartLunar() end)
                else
                    self:restartLunar()
                end
            end
        end,
        {"displays", "-j"})
    self.lunarHealthTask:start()
end

----------------------------------------------------------------------
-- Wake sequence: poll Lunar readiness before restoring
----------------------------------------------------------------------

function obj:restoreAfterWake()
    if self.state ~= "dimmed" and self.state ~= "dimming" then return end

    local startTime = hs.timer.secondsSinceEpoch()
    logAlways("Wake: waiting %.0fs before polling Lunar", self.config.wakeDelay)

    hs.timer.doAfter(self.config.wakeDelay, function()
        if self.state ~= "dimmed" and self.state ~= "dimming" then return end
        self:pollLunarAndRestore(startTime)
    end)
end

function obj:pollLunarAndRestore(startTime)
    if self.state ~= "dimmed" and self.state ~= "dimming" then return end

    local elapsed = hs.timer.secondsSinceEpoch() - startTime
    if elapsed >= self.config.wakeDelay + self.config.wakePollTimeout then
        logAlways("Wake: Lunar poll timed out after %.0fs — force restoring", elapsed)
        self:forceReset()
        return
    end

    self:getDisplaysAsync(function(displays)
        if self.state ~= "dimmed" and self.state ~= "dimming" then return end

        if next(displays) then
            logAlways("Wake: Lunar responsive after %.1fs — restoring", elapsed)
            self:restoreScreens()
        else
            logAlways("Wake: Lunar not ready (%.1fs elapsed) — retrying", elapsed)
            hs.timer.doAfter(self.config.wakePollInterval, function()
                self:pollLunarAndRestore(startTime)
            end)
        end
    end)
end

----------------------------------------------------------------------
-- Activity detection & idle checking
----------------------------------------------------------------------

function obj:onActivity()
    if self.state == "dimmed" or self.state == "dimming" then
        local now = hs.timer.secondsSinceEpoch()
        -- Ignore activity during dim cooldown
        if now - self.dimStartTime < 1.5 then return end
        -- Ignore activity during screensaver cooldown (screensaver generates events)
        if now - self.lastScreensaverEvent < self.config.screensaverCooldown then return end
        self:restoreScreens()
    end
end

----------------------------------------------------------------------
-- Watchers
----------------------------------------------------------------------

function obj:startWatchers()
    self.activityTap = hs.eventtap.new({
        hs.eventtap.event.types.keyDown,
        hs.eventtap.event.types.flagsChanged,
        hs.eventtap.event.types.leftMouseDown,
        hs.eventtap.event.types.rightMouseDown,
        hs.eventtap.event.types.mouseMoved,
        hs.eventtap.event.types.scrollWheel,
    }, function()
        self:onActivity()
        return false
    end)
    self.activityTap:start()

    self.idleCheckTimer = hs.timer.doEvery(self.config.checkInterval, function()
        if not self.enabled or self.state ~= "idle" then return end
        if self.screensaverActive then return end
        if hs.host.idleTime() >= self.config.idleTimeout then
            self:dimScreens()
        end
    end)

    if self.config.stuckTimeout > 0 then
        self.stuckCheckTimer = hs.timer.doEvery(self.config.checkInterval, function()
            self:checkStuck()
        end)
    end

    if self.config.lunarHealthInterval > 0 then
        self.lunarHealthTimer = hs.timer.doEvery(self.config.lunarHealthInterval, function()
            self:checkLunarHealth()
        end)
    end

    self.caffeinateWatcher = hs.caffeinate.watcher.new(function(event)
        if event == hs.caffeinate.watcher.systemDidWake then
            logAlways("System woke")
            self:restoreAfterWake()
        elseif event == hs.caffeinate.watcher.systemWillSleep then
            logMsg(self, "System sleeping")
            self:cancelFade()
        elseif event == hs.caffeinate.watcher.screensDidUnlock then
            logMsg(self, "Screen unlocked")
            if self.state == "dimmed" or self.state == "dimming" then
                self:restoreScreens()
            end
        elseif event == hs.caffeinate.watcher.screensDidLock then
            logMsg(self, "Screen locked")
            self:cancelFade()
        elseif event == hs.caffeinate.watcher.screensaverDidStart then
            logAlways("Screensaver started")
            self.screensaverActive = true
            self.lastScreensaverEvent = hs.timer.secondsSinceEpoch()
            -- Restore brightness so monitors don't power down while dimmed
            if self.state == "dimmed" or self.state == "dimming" then
                self:restoreScreens()
            end
            -- Pause idle checking while screensaver is active
            if self.idleCheckTimer then self.idleCheckTimer:stop() end
        elseif event == hs.caffeinate.watcher.screensaverDidStop then
            logAlways("Screensaver stopped")
            self.screensaverActive = false
            self.lastScreensaverEvent = hs.timer.secondsSinceEpoch()
            -- Restore if dimmed when screensaver stops
            if self.state == "dimmed" or self.state == "dimming" then
                self:restoreScreens()
            end
            -- Restart idle checking after cooldown
            hs.timer.doAfter(self.config.screensaverCooldown, function()
                if self.enabled and self.idleCheckTimer then
                    self.idleCheckTimer:start()
                end
            end)
        end
    end)
    self.caffeinateWatcher:start()

    self.screenWatcher = hs.screen.watcher.new(function()
        logMsg(self, "Screen configuration changed")
        if self.state == "dimmed" or self.state == "dimming" then
            self:cancelFade()
            hs.screen.restoreGamma()
            self.state = "idle"
            self.savedState = {}
            self.savedGamma = {}
        end
    end)
    self.screenWatcher:start()
end

function obj:stopWatchers()
    if self.activityTap       then self.activityTap:stop();       self.activityTap = nil       end
    if self.idleCheckTimer    then self.idleCheckTimer:stop();    self.idleCheckTimer = nil    end
    if self.stuckCheckTimer   then self.stuckCheckTimer:stop();   self.stuckCheckTimer = nil   end
    if self.lunarHealthTimer  then self.lunarHealthTimer:stop();  self.lunarHealthTimer = nil  end
    if self.lunarHealthTask   then
        if self.lunarHealthTask:isRunning() then self.lunarHealthTask:terminate() end
        self.lunarHealthTask = nil
    end
    if self.caffeinateWatcher then self.caffeinateWatcher:stop(); self.caffeinateWatcher = nil end
    if self.screenWatcher     then self.screenWatcher:stop();     self.screenWatcher = nil     end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function obj:configure(config)
    self.config = {}
    for k, v in pairs(self.defaults) do self.config[k] = v end
    if config then
        for k, v in pairs(config) do self.config[k] = v end
    end
    return self
end

function obj:start()
    if not next(self.config) then self:configure({}) end

    -- Check accessibility permissions (required for eventtap)
    if not hs.accessibilityState() then
        logAlways("Accessibility permission not granted — requesting")
        hs.alert.show("ScreenDimmer needs Accessibility permission")
        -- Prompt for permission (opens System Settings)
        hs.accessibilityState(true)
        return self
    end

    self.enabled    = true
    self.state      = "idle"
    self.savedState = {}
    self.savedGamma = {}
    self:startWatchers()
    logAlways("ScreenDimmer started (timeout=%ds, fade=%.1fs)",
        self.config.idleTimeout, self.config.fadeDuration)
    return self
end

function obj:stop()
    self.enabled = false
    if self.state == "dimmed" or self.state == "dimming" then
        self:restoreScreens()
    end
    self:cancelFade()
    hs.screen.restoreGamma()
    self:stopWatchers()
    -- Hotkeys are intentionally NOT deleted here so toggle can re-enable
    logAlways("ScreenDimmer stopped")
    return self
end

function obj:toggle()
    if self.enabled then
        self:stop()
        hs.alert.show("ScreenDimmer disabled")
    else
        self:start()
        hs.alert.show("ScreenDimmer enabled")
    end
    return self
end

function obj:dimNow()
    if not self.enabled then return self end
    if self.state == "dimmed" or self.state == "dimming" then
        self:restoreScreens()
    else
        self:dimScreens()
    end
    return self
end

function obj:bindHotkeys(mapping)
    if mapping.toggle then
        table.insert(self.hotkeys,
            hs.hotkey.bind(mapping.toggle[1], mapping.toggle[2],
                function() self:toggle() end))
    end
    if mapping.dim then
        table.insert(self.hotkeys,
            hs.hotkey.bind(mapping.dim[1], mapping.dim[2],
                function() self:dimNow() end))
    end
    if mapping.reset then
        table.insert(self.hotkeys,
            hs.hotkey.bind(mapping.reset[1], mapping.reset[2],
                function()
                    self:forceReset()
                    hs.alert.show("ScreenDimmer: force reset")
                end))
    end
    return self
end

function obj:listDisplays()
    dofile(hs.configdir .. "/Spoons/ScreenDimmer.spoon/list_displays.lua")
end

function obj:display(dimLevel, priority, minBrightness)
    local d = { dimLevel = dimLevel }
    if priority then d.priority = priority end
    if minBrightness then d.minBrightness = minBrightness end
    return d
end

return obj
