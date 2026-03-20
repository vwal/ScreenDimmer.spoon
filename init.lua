--- === ScreenDimmer ===
---
--- Dims screens after inactivity using smooth gamma fades, with Lunar Pro
--- for state management. Supports deep subzero dimming levels.
--- Each display can be configured individually or by category (internal/external).
---
--- ARCHITECTURE:
---   External displays use hs.screen:setGamma() at ~30fps for buttery
---   smooth transitions, all fading simultaneously. The gamma overlay stays
---   applied while dimmed (no handoff to Lunar subzero).
---   Internal (built-in) display uses Lunar CLI subzero fade (macOS protects
---   the internal display's gamma table, so setGamma() is ineffective).
---   Both paths run in parallel so the internal display fades at the same
---   time as externals. Lunar CLI is also used to disable adaptiveSubzero
---   during dimming (prevent interference) and re-enable it on restore.
---
---   Display mapping: hs.screen:getUUID() matches Lunar's display serial
---   (both use CGDisplayCreateUUIDFromDisplayID internally).
---
--- Dim level convention:
---   Positive (1–100): hardware brightness target
---   Zero: hardware brightness 0
---   Negative (-1 to -100): subzero dimming via gamma overlay
---     Formula: whitepoint = (100 + dimLevel) / 100
---     Examples: -30 → 0.70, -80 → 0.20, -99 → 0.01

local obj = {}
obj.__index = obj

-- Spoon metadata
obj.name = "ScreenDimmer"
obj.version = "2.0"
obj.author = ""
obj.license = "MIT"

local log = hs.logger.new("ScreenDimmer", "info")

----------------------------------------------------------------------
-- Configuration defaults
----------------------------------------------------------------------

obj.defaults = {
    idleTimeout      = 300,      -- seconds before dimming
    fadeDuration     = 2.0,      -- seconds for smooth gamma fade
    fadeInterval     = 0.033,    -- ~30fps gamma updates
    checkInterval    = 5,        -- idle-check frequency (seconds)
    lunarPath        = os.getenv("HOME") .. "/.local/bin/lunar",

    -- Category defaults for dim level
    internalDimLevel  = -30,     -- built-in display
    externalDimLevel  = -80,     -- external displays

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
    self.savedState = {}
    self.savedGamma = {}

    self:getDisplaysAsync(function(displays)
        if self.state ~= "dimming" then return end

        if not next(displays) then
            logAlways("No displays found — aborting dim")
            self.state = "idle"
            return
        end

        -- Separate displays into gamma targets (external) and Lunar targets (internal)
        local gammaTargets = {}
        local lunarInternalCmds = {}  -- internal: preamble + fade (runs first)
        local lunarExternalCmds = {}  -- external: adaptiveSubzero false (runs after)

        for serial, d in pairs(displays) do
            local dimLevel = self:getDimLevel(serial, d.isInternal)
            local priority = self:getDisplayPriority(serial, d.isInternal)

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

            if d.isInternal then
                -- Internal display: setGamma doesn't work, use Lunar CLI subzero
                logAlways("Dim %s (%s…): brightness %d → level %d [priority %d] [Lunar]",
                    d.name, serial:sub(1, 8), d.brightness, dimLevel, priority)

                table.insert(lunarInternalCmds, self:lunarCmd(serial, "adaptiveSubzero", false))
                if dimLevel < 0 then
                    local targetSZD = (100 + dimLevel) / 100
                    table.insert(lunarInternalCmds, self:lunarCmd(serial, "subzero", true))
                    table.insert(lunarInternalCmds, self:lunarCmd(serial, "subzeroDimming", 1.0))
                    table.insert(lunarInternalCmds, "sleep 0.1")
                    -- More steps, no extra sleep — Lunar's ~250ms latency paces naturally
                    -- 8 steps × ~250ms ≈ 2s, matching gamma fade duration
                    local steps = 8
                    local gamma_exp = 2.2
                    local from_p = 1.0
                    local to_p   = targetSZD ^ (1 / gamma_exp)
                    local lastVal = nil
                    for step = 1, steps do
                        local progress = step / steps
                        local p_val = from_p + (to_p - from_p) * progress
                        local raw = p_val ^ gamma_exp
                        local value = math.floor(raw * 100 + 0.5) / 100
                        if value ~= lastVal then
                            table.insert(lunarInternalCmds, self:lunarCmd(serial, "subzeroDimming", value))
                            lastVal = value
                        end
                    end
                end
            else
                -- External display: smooth gamma fade via setGamma
                logAlways("Dim %s (%s…): brightness %d → level %d [priority %d] [gamma]",
                    d.name, serial:sub(1, 8), d.brightness, dimLevel, priority)

                table.insert(lunarExternalCmds, self:lunarCmd(serial, "adaptiveSubzero", false))

                if dimLevel < 0 then
                    local targetWP = (100 + dimLevel) / 100
                    table.insert(gammaTargets, {
                        uuid   = serial,
                        fromWP = 1.0,
                        toWP   = targetWP,
                    })
                else
                    local targetWP = dimLevel / math.max(d.brightness, 1)
                    targetWP = math.max(0.01, math.min(1.0, targetWP))
                    table.insert(gammaTargets, {
                        uuid   = serial,
                        fromWP = 1.0,
                        toWP   = targetWP,
                    })
                end
            end
        end

        -- Build Lunar script: internal first (time-critical), external adaptive last
        local lunarCmds = {}
        for _, cmd in ipairs(lunarInternalCmds) do table.insert(lunarCmds, cmd) end
        for _, cmd in ipairs(lunarExternalCmds) do table.insert(lunarCmds, cmd) end

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
    logAlways("Starting restore sequence")

    if not next(self.savedState) then
        logAlways("No saved state to restore from")
        hs.screen.restoreGamma()
        self.state = "idle"
        return
    end

    -- Separate into gamma targets (external) and Lunar targets (internal)
    local gammaTargets = {}
    local lunarCmds = {}

    for serial, saved in pairs(self.savedState) do
        local dimLevel = self:getDimLevel(serial, saved.isInternal)

        if saved.isInternal then
            -- Internal: restore via Lunar CLI subzero fade
            if dimLevel < 0 then
                local curSZD = (100 + dimLevel) / 100
                local steps = 8
                local gamma_exp = 2.2
                local from_p = curSZD ^ (1 / gamma_exp)
                local to_p   = 1.0
                local lastVal = nil
                for step = 1, steps do
                    local progress = step / steps
                    local p_val = from_p + (to_p - from_p) * progress
                    local raw = p_val ^ gamma_exp
                    local value = math.floor(raw * 100 + 0.5) / 100
                    if value ~= lastVal then
                        table.insert(lunarCmds, self:lunarCmd(serial, "subzeroDimming", value))
                        lastVal = value
                    end
                end
                -- Restore original subzero state
                if saved.subzero then
                    table.insert(lunarCmds, self:lunarCmd(serial, "subzeroDimming", saved.subzeroDimming))
                else
                    table.insert(lunarCmds, self:lunarCmd(serial, "subzero", false))
                end
            end
            table.insert(lunarCmds, self:lunarCmd(serial, "adaptiveSubzero", true))
        else
            -- External: smooth gamma fade back to 1.0
            local fromWP
            if dimLevel < 0 then
                fromWP = (100 + dimLevel) / 100
            else
                fromWP = dimLevel / math.max(saved.brightness, 1)
                fromWP = math.max(0.01, math.min(1.0, fromWP))
            end
            table.insert(gammaTargets, {
                uuid   = serial,
                fromWP = fromWP,
                toWP   = 1.0,
            })
        end
    end

    -- Add adaptiveSubzero true for external displays (after gamma fade completes)
    local externalSerials = {}
    for serial, saved in pairs(self.savedState) do
        if not saved.isInternal then
            table.insert(externalSerials, serial)
        end
    end

    -- Run Lunar script and gamma fade in parallel
    local pending = 0
    local function onPartDone()
        pending = pending - 1
        if pending == 0 and self.state == "restoring" then
            hs.screen.restoreGamma()
            -- Re-enable adaptive for external displays
            if #externalSerials > 0 then
                local cmds = {}
                for _, serial in ipairs(externalSerials) do
                    table.insert(cmds, self:lunarCmd(serial, "adaptiveSubzero", true))
                end
                self:runLunarScript(cmds, nil)
            end
            self.state = "idle"
            self.savedState = {}
            self.savedGamma = {}
            logAlways("All displays restored")
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
        hs.screen.restoreGamma()
        self.state = "idle"
        self.savedState = {}
        self.savedGamma = {}
        logAlways("Nothing to restore")
    end
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
