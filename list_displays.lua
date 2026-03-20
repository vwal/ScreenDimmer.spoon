#!/usr/bin/env lua
--- list_displays.lua — Show connected displays with UUIDs for ScreenDimmer config.
---
--- Run from Hammerspoon console:
---   spoon.ScreenDimmer:listDisplays()
---
--- Or directly:
---   dofile(hs.configdir .. "/Spoons/ScreenDimmer.spoon/list_displays.lua")

local screens = hs.screen.allScreens()
local lunarPath = os.getenv("HOME") .. "/.local/bin/lunar"

-- Try to get display names from Lunar JSON
local lunarNames = {}
local output, ok = hs.execute(lunarPath .. " displays -j")
if ok and output and output ~= "" then
    local success, data = pcall(hs.json.decode, output)
    if success and data then
        for serial, info in pairs(data) do
            if info.name then
                lunarNames[serial] = info.name
            end
        end
    end
end

print("\n--- Connected Displays ---\n")

local entries = {}
for i, s in ipairs(screens) do
    local uuid = s:getUUID()
    local name = lunarNames[uuid] or s:name() or "Unknown"
    local isInternal = (name == "Built-in" or name:find("Built%-in") or name:find("Retina"))
    table.insert(entries, {
        uuid = uuid,
        name = name,
        isInternal = isInternal,
        index = i,
    })
end

-- Print summary
for _, e in ipairs(entries) do
    print(string.format("  %d. %s %s", e.index, e.name, e.isInternal and "(internal)" or ""))
    print(string.format("     UUID: %s", e.uuid))
end

-- Print config snippet
print("\n--- ScreenDimmer config snippet ---\n")
print("    displays = {")
for i, e in ipairs(entries) do
    local level = e.isInternal and -30 or -80
    print(string.format('        ["%s"] = dimmer:display(%d, %d),  -- %s',
        e.uuid, level, i, e.name))
end
print("    },")
print("")
