--- === ScreenDimmer ===
---
--- Dims screens after inactivity using Lunar Pro, with smooth fade transitions.
--- Supports subzero (gamma) dimming for deeper-than-hardware dim levels.
--- Each display can be configured individually or by category (internal/external).
---
--- ARCHITECTURE: Fully async. No hs.execute calls. All Lunar CLI interactions
--- use hs.task.new with callbacks so the main Hammerspoon thread never blocks.
--- Fades run as a single shell script process to prevent process pileup.
--- Displays are faded ONE AT A TIME in priority order, each through its
--- full preamble → fade steps → postamble sequence. All Lunar commands
--- are sequential (no backgrounding) since Lunar serializes CLI requests.
--- adaptiveSubzero is disabled during fades to prevent Lunar's adaptive
--- algorithm from fighting our manual values. Interpolation uses gamma-
--- corrected perceptual space so each step looks like an equal change.
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
    fadeSteps         = 5,       -- steps in fade animation
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

--- Resolve the priority for a display: per-display override → category default.
function obj:getDisplayPriority(serial, isInternal)
    local dc = self.config.displays[serial]
    if dc and dc.priority then return dc.priority end
    return isInternal and 100 or 200
end

----------------------------------------------------------------------
-- Fade engine
--
-- Generates a complete shell script that fades displays ONE AT A TIME,
-- each through its full preamble → steps → postamble sequence, in
-- priority order. All commands are sequential (no & or wait) since
-- Lunar serializes CLI requests anyway.
----------------------------------------------------------------------

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

--- Build and run a per-display sequential fade as a single shell script.
---
--- `displayFades`: ordered list of per-display fade specs:
---   { serial, name, preambleCmds, channels: [{property, from, to}], postambleCmds }
--- `callback`: function called when script finishes (or is cancelled)
function obj:runFade(displayFades, callback)
    self:cancelFade()

    local steps     = self.config.fadeSteps
    local stepDelay = self.config.fadeStepDelay
    local logging   = self.config.logging
    local lines     = {
        "trap 'exit 1' TERM INT",
    }

    local totalCmds = 0
    local stepLog = {}

    for _, df in ipairs(displayFades) do
        if logging then
            table.insert(lines, string.format(
                "echo \"DISPLAY %s start $(date +%%H:%%M:%%S)\" >&2",
                df.serial:sub(1, 4)))
        end

        -- Per-display preamble (sequential)
        for _, cmd in ipairs(df.preambleCmds or {}) do
            table.insert(lines, cmd)
            totalCmds = totalCmds + 1
        end
        if df.preambleCmds and #df.preambleCmds > 0 then
            table.insert(lines, "sleep 0.1")
        end

        -- Fade steps for this display (sequential)
        local lastVals = {}
        for i = 1, #df.channels do lastVals[i] = nil end

        for step = 1, steps do
            local progress = step / steps
            local vals = {}
            local emitted = 0

            for i, ch in ipairs(df.channels) do
                local raw
                if ch.property == "subzeroDimming" then
                    local gamma = 2.2
                    local from_p = ch.from ^ (1 / gamma)
                    local to_p   = ch.to   ^ (1 / gamma)
                    local p_val  = from_p + (to_p - from_p) * progress
                    raw = p_val ^ gamma
                else
                    raw = ch.from + (ch.to - ch.from) * progress
                end

                local value
                if ch.property == "brightness" then
                    value = math.floor(raw + 0.5)
                else
                    value = math.floor(raw * 100 + 0.5) / 100
                end

                table.insert(vals, string.format("%.2f", value))

                if value ~= lastVals[i] then
                    lastVals[i] = value
                    table.insert(lines, self:lunarCmd(df.serial, ch.property, value))
                    totalCmds = totalCmds + 1
                    emitted = emitted + 1
                end
            end

            table.insert(stepLog, string.format("  %s step %2d (p=%.3f): %s%s",
                df.serial:sub(1, 4), step, progress, table.concat(vals, ", "),
                emitted > 0 and "" or " [skip]"))

            if stepDelay > 0 and step < steps then
                table.insert(lines, string.format("sleep %.3f", stepDelay))
            end
        end

        -- Per-display postamble (sequential)
        for _, cmd in ipairs(df.postambleCmds or {}) do
            table.insert(lines, cmd)
            totalCmds = totalCmds + 1
        end

        if logging then
            table.insert(lines, string.format(
                "echo \"DISPLAY %s done  $(date +%%H:%%M:%%S)\" >&2",
                df.serial:sub(1, 4)))
        end
    end

    local script = table.concat(lines, "\n")

    logAlways("Fade: %d displays, %d steps/display, %d total cmds, %d script lines",
        #displayFades, steps, totalCmds, #lines)
    logAlways("Fade steps:\n%s", table.concat(stepLog, "\n"))

    self.fadeTask = hs.task.new("/bin/sh", function(exitCode, stdOut, stdErr)
        self.fadeTask = nil
        if stdErr and stdErr ~= "" then
            logAlways("Fade timing:\n%s", stdErr)
        end
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

        -- Build sorted list of displays by priority
        local displayList = {}
        for serial, d in pairs(displays) do
            table.insert(displayList, {
                serial   = serial,
                info     = d,
                priority = self:getDisplayPriority(serial, d.isInternal),
            })
        end
        table.sort(displayList, function(a, b)
            if a.priority ~= b.priority then return a.priority < b.priority end
            return a.serial < b.serial
        end)

        -- Build per-display fade specs
        local displayFades = {}
        for _, entry in ipairs(displayList) do
            local serial = entry.serial
            local d = entry.info
            local dimLevel = self:getDimLevel(serial, d.isInternal)

            self.savedState[serial] = {
                brightness     = d.brightness,
                subzero        = d.subzero,
                subzeroDimming = d.subzeroDimming,
                isInternal     = d.isInternal,
                name           = d.name,
            }

            logAlways("Dim %s (%s…): brightness %d → level %d [priority %d]",
                d.name, serial:sub(1, 8), d.brightness, dimLevel, entry.priority)

            if dimLevel < 0 then
                local targetSZD = (100 + dimLevel) / 100
                table.insert(displayFades, {
                    serial = serial,
                    name = d.name,
                    preambleCmds = {
                        self:lunarCmd(serial, "adaptiveSubzero", false),
                        self:lunarCmd(serial, "subzero", true),
                        self:lunarCmd(serial, "subzeroDimming", 1.0),
                    },
                    channels = { { property = "subzeroDimming", from = 1.0, to = targetSZD } },
                    postambleCmds = {},
                })
            else
                table.insert(displayFades, {
                    serial = serial,
                    name = d.name,
                    preambleCmds = {},
                    channels = { { property = "brightness", from = d.brightness, to = dimLevel } },
                    postambleCmds = {},
                })
            end
        end

        self:runFade(displayFades, function(ok)
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

        -- Build sorted list by priority (same order as dim)
        local displayList = {}
        for serial, saved in pairs(self.savedState) do
            table.insert(displayList, {
                serial   = serial,
                saved    = saved,
                priority = self:getDisplayPriority(serial, saved.isInternal),
            })
        end
        table.sort(displayList, function(a, b)
            if a.priority ~= b.priority then return a.priority < b.priority end
            return a.serial < b.serial
        end)

        -- Build per-display fade specs
        local displayFades = {}
        for _, entry in ipairs(displayList) do
            local serial = entry.serial
            local saved = entry.saved
            local dimLevel = self:getDimLevel(serial, saved.isInternal)
            local cur = currentDisplays[serial]

            logAlways("Restore %s (%s…) → brightness %d [priority %d]",
                saved.name or "?", serial:sub(1, 8), saved.brightness, entry.priority)

            if dimLevel < 0 then
                local curSZD = (cur and cur.subzeroDimming) or (100 + dimLevel) / 100
                local postCmds = {}
                if saved.subzero then
                    table.insert(postCmds,
                        self:lunarCmd(serial, "subzeroDimming", saved.subzeroDimming))
                else
                    table.insert(postCmds,
                        self:lunarCmd(serial, "subzero", false))
                end
                table.insert(postCmds,
                    self:lunarCmd(serial, "adaptiveSubzero", true))

                table.insert(displayFades, {
                    serial = serial,
                    name = saved.name or serial,
                    preambleCmds = {
                        self:lunarCmd(serial, "adaptiveSubzero", false),
                    },
                    channels = { { property = "subzeroDimming", from = curSZD, to = 1.0 } },
                    postambleCmds = postCmds,
                })
            else
                local curBr = (cur and cur.brightness) or dimLevel
                table.insert(displayFades, {
                    serial = serial,
                    name = saved.name or serial,
                    preambleCmds = {},
                    channels = { { property = "brightness", from = curBr, to = saved.brightness } },
                    postambleCmds = {},
                })
            end
        end

        self:runFade(displayFades, function(ok)
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

function obj:display(dimLevel, priority)
    local d = { dimLevel = dimLevel }
    if priority then d.priority = priority end
    return d
end

return obj
