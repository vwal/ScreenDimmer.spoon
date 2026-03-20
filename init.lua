--- === ScreenDimmer ===
---
--- Dims screens after inactivity using Lunar Pro, with smooth fade transitions.
--- Supports subzero (gamma) dimming for deeper-than-hardware dim levels.
--- Each display can be configured individually or by category (internal/external).
---
--- ARCHITECTURE: Fully async. No hs.execute calls. All Lunar CLI interactions
--- use hs.task.new with callbacks so the main Hammerspoon thread never blocks.
--- Fades run as a single shell script process to prevent process pileup.
--- Each fade step runs all display commands in parallel (& wait) for
--- synchronized updates. adaptiveSubzero is disabled during fades to
--- prevent Lunar's adaptive algorithm from fighting our manual values.
---
--- Dim level convention:
---   Positive (1–100): hardware brightness target
---   Zero: hardware brightness 0
---   Negative (-1 to -100): subzero dimming via Lunar's gamma overlay
---     Formula: subzeroDimming = (100 + dimLevel) / 100
---     Examples: -30 → 0.70, -80 → 0.20, -99 → 0.01

local obj = {}
obj.__index = obj

-- Spoon metadata
obj.name = "ScreenDimmer"
obj.version = "1.0"
obj.author = ""
obj.license = "MIT"

local log = hs.logger.new("ScreenDimmer", "info")

----------------------------------------------------------------------
-- Configuration defaults
----------------------------------------------------------------------

obj.defaults = {
    idleTimeout      = 300,      -- seconds before dimming
    fadeSteps         = 7,       -- steps in fade animation
    fadeStepDelay     = 0,       -- 0 = no extra sleep; Lunar's latency paces the fade
    checkInterval     = 5,       -- idle-check frequency (seconds)
    lunarPath         = os.getenv("HOME") .. "/.local/bin/lunar",

    -- Category defaults for dim level
    internalDimLevel  = -30,     -- built-in display
    externalDimLevel  = -80,     -- external displays

    -- Per-display overrides keyed by Lunar serial
    displays          = {},

    logging           = true,   -- TODO: set to false once fade is tuned
}

----------------------------------------------------------------------
-- Instance state
----------------------------------------------------------------------

obj.config            = {}
obj.state             = "idle"   -- idle | dimming | dimmed | restoring
obj.savedState        = {}       -- per-serial saved brightness before dim
obj.fadeTask          = nil      -- single hs.task running the fade script
obj.queryTask         = nil      -- hs.task for async display queries
obj.enabled           = false
obj.dimStartTime      = 0        -- for activity cooldown
obj.activityTap       = nil
obj.idleCheckTimer    = nil
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

--- Query Lunar for all active displays via JSON (ASYNC, non-blocking).
--- Calls callback(displays) where displays is { serial → { name, isInternal, ... } }.
--- Returns empty table on failure.
function obj:getDisplaysAsync(callback)
    -- Cancel any outstanding query
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

--- Resolve the dim level for a display: per-display override → category default.
function obj:getDimLevel(serial, isInternal)
    local dc = self.config.displays[serial]
    if dc and dc.dimLevel then return dc.dimLevel end
    return isInternal and self.config.internalDimLevel or self.config.externalDimLevel
end

----------------------------------------------------------------------
-- Fade engine
--
-- Generates a complete shell script that performs the entire fade as
-- a SINGLE process. Each step runs Lunar commands in parallel (via &),
-- waits for completion, then sleeps. Uses trap to kill children on
-- cancellation.
----------------------------------------------------------------------

--- Cubic ease-in-out for smooth visual transitions.
local function easeInOutCubic(t)
    if t < 0.5 then
        return 4 * t * t * t
    else
        return 1 - math.pow(-2 * t + 2, 3) / 2
    end
end

--- Cancel the active fade task (and its child processes) if running.
function obj:cancelFade()
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

--- Build and run a fade as a single shell script.
---
--- `channels`: list of { serial, property, from, to }
--- `preambleCmds`: shell commands run before the fade (e.g., subzero enable)
--- `postambleCmds`: shell commands run after the fade (e.g., subzero disable)
--- `callback`: function called when script finishes (or is cancelled)
function obj:runFade(channels, preambleCmds, postambleCmds, callback)
    self:cancelFade()

    local steps     = self.config.fadeSteps
    local stepDelay = self.config.fadeStepDelay
    local lines     = {
        "trap 'kill $(jobs -p) 2>/dev/null; exit 1' TERM INT",
    }

    -- Preamble: run per-display setup groups in parallel, then settle
    if preambleCmds and #preambleCmds > 0 then
        table.insert(lines, table.concat(preambleCmds, " & ") .. " & wait")
        table.insert(lines, "sleep 0.1")
    end

    -- Pre-compute all step values, skipping redundant commands.
    -- Commands run in parallel per step (& wait) so all displays
    -- update at the same target level in each step.
    local lastVals = {}
    for i = 1, #channels do lastVals[i] = nil end

    local totalCmds = 0
    local stepLog = {}
    for step = 1, steps do
        local progress = step / steps  -- linear for consistent per-step changes
        local cmds = {}
        local vals = {}

        for i, ch in ipairs(channels) do
            local raw = ch.from + (ch.to - ch.from) * progress
            local value
            if ch.property == "brightness" then
                value = math.floor(raw + 0.5)
            else
                value = math.floor(raw * 100 + 0.5) / 100
            end

            table.insert(vals, string.format("%s=%.2f", ch.serial:sub(1,4), value))

            if value ~= lastVals[i] then
                lastVals[i] = value
                table.insert(cmds, self:lunarCmd(ch.serial, ch.property, value))
            end
        end

        if #cmds > 0 then
            table.insert(lines, table.concat(cmds, " & ") .. " & wait")
            totalCmds = totalCmds + #cmds
        end

        table.insert(stepLog, string.format("  step %2d (p=%.3f): %s [%d cmds]",
            step, progress, table.concat(vals, ", "), #cmds))

        if stepDelay > 0 and step < steps then
            table.insert(lines, string.format("sleep %.3f", stepDelay))
        end
    end

    -- Postamble: run cleanup commands in parallel
    if postambleCmds and #postambleCmds > 0 then
        table.insert(lines, table.concat(postambleCmds, " & ") .. " & wait")
    end

    local script = table.concat(lines, "\n")

    logAlways("Fade: %d channels, %d steps, %d total cmds, %d script lines",
        #channels, steps, totalCmds, #lines)
    logAlways("Fade steps:\n%s", table.concat(stepLog, "\n"))

    self.fadeTask = hs.task.new("/bin/sh", function(exitCode, stdOut, stdErr)
        self.fadeTask = nil
        if callback then callback(exitCode == 0) end
    end, {"-c", script})
    self.fadeTask:start()
end

----------------------------------------------------------------------
-- Dim operation
----------------------------------------------------------------------

function obj:dimScreens()
    if self.state == "dimming" or self.state == "dimmed" then return end

    logAlways("Starting dim sequence")
    self.state = "dimming"
    self.dimStartTime = hs.timer.secondsSinceEpoch()
    self.savedState = {}

    self:getDisplaysAsync(function(displays)
        -- Guard: state may have changed while waiting for async query
        if self.state ~= "dimming" then return end

        if not next(displays) then
            logAlways("No displays found — aborting dim")
            self.state = "idle"
            return
        end

        local preambleCmds = {}
        local channels = {}

        for serial, d in pairs(displays) do
            local dimLevel = self:getDimLevel(serial, d.isInternal)

            self.savedState[serial] = {
                brightness     = d.brightness,
                subzero        = d.subzero,
                subzeroDimming = d.subzeroDimming,
                isInternal     = d.isInternal,
            }

            logAlways("Dim %s (%s…): brightness %d → level %d",
                d.name, serial:sub(1, 8), d.brightness, dimLevel)

            if dimLevel < 0 then
                local targetSZD = (100 + dimLevel) / 100

                -- Preamble per display (grouped with && so they run in order):
                --   1. Set subzeroDimming=1.0 first (no visible effect yet)
                --   2. Disable adaptiveSubzero so Lunar doesn't fight our fade
                --   3. Enable subzero mode (at level 1.0 = no visible dimming)
                local szdCmd   = self:lunarCmd(serial, "subzeroDimming", 1.0)
                local adaptCmd = self:lunarCmd(serial, "adaptiveSubzero", false)
                local szCmd    = self:lunarCmd(serial, "subzero", true)
                table.insert(preambleCmds,
                    "(" .. szdCmd .. " && " .. adaptCmd .. " && " .. szCmd .. ")")

                -- Only fade subzeroDimming — don't touch hardware brightness.
                -- Changing both causes flashing (Lunar's adaptive brightness
                -- fights our brightness changes). Hardware brightness alone
                -- can't go below 0, and brightness=0 means backlight off = black.
                table.insert(channels, { serial = serial, property = "subzeroDimming",
                    from = 1.0, to = targetSZD })
            else
                table.insert(channels, { serial = serial, property = "brightness",
                    from = d.brightness, to = dimLevel })
            end
        end

        self:runFade(channels, preambleCmds, nil, function(ok)
            if self.state == "dimming" then
                self.state = "dimmed"
                logAlways("All displays dimmed")
            end
        end)
    end)
end

----------------------------------------------------------------------
-- Restore operation
----------------------------------------------------------------------

function obj:restoreScreens()
    if self.state ~= "dimmed" and self.state ~= "dimming" then return end

    self:cancelFade()
    self.state = "restoring"
    logAlways("Starting restore sequence")

    if not next(self.savedState) then
        logAlways("No saved state to restore from")
        self.state = "idle"
        return
    end

    self:getDisplaysAsync(function(currentDisplays)
        if self.state ~= "restoring" then return end

        local channels = {}
        local restorePreambleCmds = {}

        for serial, saved in pairs(self.savedState) do
            local dimLevel = self:getDimLevel(serial, saved.isInternal)
            local cur = currentDisplays[serial]

            logAlways("Restore %s… → brightness %d", serial:sub(1, 8), saved.brightness)

            if dimLevel < 0 then
                local curSZD = (cur and cur.subzeroDimming) or (100 + dimLevel) / 100

                -- Ensure adaptive is off during restore fade too
                table.insert(restorePreambleCmds,
                    self:lunarCmd(serial, "adaptiveSubzero", false))

                -- Only restore subzeroDimming (brightness was never changed)
                table.insert(channels, { serial = serial, property = "subzeroDimming",
                    from = curSZD, to = 1.0 })
            else
                local curBr = (cur and cur.brightness) or dimLevel
                table.insert(channels, { serial = serial, property = "brightness",
                    from = curBr, to = saved.brightness })
            end
        end

        -- Postamble: clean up subzero state and re-enable adaptive
        local postCmds = {}
        for serial, saved in pairs(self.savedState) do
            local dimLevel = self:getDimLevel(serial, saved.isInternal)
            if dimLevel < 0 then
                if saved.subzero then
                    table.insert(postCmds,
                        self:lunarCmd(serial, "subzeroDimming", saved.subzeroDimming))
                else
                    table.insert(postCmds,
                        self:lunarCmd(serial, "subzero", false))
                end
                -- Re-enable adaptive subzero control
                table.insert(postCmds,
                    self:lunarCmd(serial, "adaptiveSubzero", true))
            end
        end

        self:runFade(channels, restorePreambleCmds, postCmds, function(ok)
            self.state = "idle"
            logAlways("All displays restored")
        end)
    end)
end

----------------------------------------------------------------------
-- Activity detection & idle checking
----------------------------------------------------------------------

function obj:onActivity()
    if self.state == "dimmed" or self.state == "dimming" then
        local elapsed = hs.timer.secondsSinceEpoch() - self.dimStartTime
        if elapsed < 1.5 then return end
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
        if hs.host.idleTime() >= self.config.idleTimeout then
            self:dimScreens()
        end
    end)

    self.caffeinateWatcher = hs.caffeinate.watcher.new(function(event)
        if event == hs.caffeinate.watcher.systemDidWake then
            logMsg(self, "System woke")
            hs.timer.doAfter(3, function()
                if self.state == "dimmed" or self.state == "dimming" then
                    self:restoreScreens()
                end
            end)
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
        end
    end)
    self.caffeinateWatcher:start()

    self.screenWatcher = hs.screen.watcher.new(function()
        logMsg(self, "Screen configuration changed")
        if self.state == "dimmed" or self.state == "dimming" then
            self:cancelFade()
            self.state = "idle"
            self.savedState = {}
        end
    end)
    self.screenWatcher:start()
end

function obj:stopWatchers()
    if self.activityTap       then self.activityTap:stop();       self.activityTap = nil       end
    if self.idleCheckTimer    then self.idleCheckTimer:stop();    self.idleCheckTimer = nil    end
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
    self.enabled    = true
    self.state      = "idle"
    self.savedState = {}
    self:startWatchers()
    logAlways("ScreenDimmer started (timeout=%ds)", self.config.idleTimeout)
    return self
end

function obj:stop()
    self.enabled = false
    if self.state == "dimmed" or self.state == "dimming" then
        self:restoreScreens()
    end
    self:cancelFade()
    self:stopWatchers()
    for _, hk in ipairs(self.hotkeys) do hk:delete() end
    self.hotkeys = {}
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
    return self
end

function obj:display(dimLevel)
    return { dimLevel = dimLevel }
end

return obj
