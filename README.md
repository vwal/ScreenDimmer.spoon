# macOS screen dimmer spoon

A lua script "spoon" for [Hammerspoon](https://www.hammerspoon.org/) to dim MacBook Pro's internal screen and any external DCC-compatible monitors to a preset luminosity (10% by default) after a preset period of inactivity (5 minutes by default) has elapsed.

NOTE: This new version has been rewritten to make use of [Lunar Pro CLI](https://lunar.fyi/) utility. As a result, this script now automatically supports all DCC-capable monitors. Some additional features have also been implemented:

- The gamma mode ("subzero") is supported via Lunar's capability. `dimLevel` values 1-100 correspond to the hardware-based brightness, whereas values -1 through -100 correspond to the gamma shader values.
- Optional `internalDisplayGainLevel` is implemented to have the MacBook Pro's internal display at a different dimness level from the external monitor(s). You can define a positive or negative value. However, usually, a positive value is used because the internal display tends to appear darker than external monitors at the same `dimLevel`.
- Optional `displayPriorities` can be defined to change the default order in which the displays are dimmed and restored. The sequence happens pretty quickly, but you may nevertheless want your primary monitor to be dimmed/restored first.
- Automatic handling of connected/disconnected monitors without the need to reload the spoon.

I use this script when I don't want to use the screen saver and/or screen sleep, but, on the other hand, I don't want to keep the screen at normal brightness when I don't actively use the system. The original brightness is restored on the first user interaction (keyboard/mouse/trackpad). Handles brightness restoration correctly after screen saver, lock-screen, and screen sleep.

Save the script at `~/.hammerspoon/Spoons/ScreenDimmer.spoon`, and call it from `~/.hammerspoon/init.lua` as shown below. Please note that you *must* define the path to the lunar CLI utility (use `which lunar` to determine its location):

```
-- Load ScreenDimmer Spoon
local dimmer = hs.loadSpoon("ScreenDimmer")

-- Configure the Spoon
dimmer:configure({
    lunarPath = "/Users/myhomedir/.local/bin/lunar",  -- get your path with `which lunar`
    idleTimeout = 300,  -- 5 minutes in seconds, adjust as needed
    dimLevel = -75,     -- negative values use "subzero", i.e. gamma shader
    logging = false,    -- set to `true` for debug logging
    internalDisplayGainLevel = 50,  -- dim the MBP internal display to 50 points brighter
                                    -- than the `dimLevel` setting, i.e. here to -25
    displayPriorities = {  -- example monitor priorities; get your monitor names using
                           -- `lunar displays`
        ["Built-in"] = 1,
        ["BenQ PD3225U"] = 2,
        ["LG Ultra HD"] = 3
    }
}):start()

-- Bind hotkey
dimmer:bindHotkeys({
    toggle = { {"shift", "cmd", "alt", "ctrl"}, "D" },  -- Enable/disable the dimmer
    dim = { {"shift", "cmd", "alt"}, "D" }              -- Immediate dim toggle
})
```

Above, I've set a hyperkey+D to toggle the dimmer on/off and ⇧⎇⌘+D to dim the screen(s) immediately (note: you can define both, either, or no hotkeys). If no hotkeys are defined when calling ScreenDimmer, none are set internally.

Tested with macOS Sequoia and Hammerspoon 1.0.0. Provided without guarantees (= use at your own risk).

MIT license.

