# macOS screen dimmer spoon

A lua script "spoon" for [Hammerspoon](https://www.hammerspoon.org/) to dim MacBook Pro's internal screen and any external DCC-compatible monitors to a preset luminosity (10% by default) after a preset period of inactivity (5 minutes by default) has elapsed.

I use this when I don't want to use the screen saver and/or screen sleep, but, on the other hand, I don't want to keep the screen at normal brightness when I don't actively use the system. The original brightness is restored on the first user interaction (keyboard/mouse/trackpad). Handles brightness restoration correctly after screen saver, lock-screen, and screen sleep.

I have it at `~/.hammerspoon/Spoons/ScreenDimmer.spoon`, and call it from `~/.hammerspoon/init.lua`, like so:

```
-- Load ScreenDimmer Spoon
local dimmer = hs.loadSpoon("ScreenDimmer")

-- Configure with desired settings
dimmer:configure({
    idleTimeout =  240,  -- 4 minutes in seconds
    dimPercentage = 10,  -- dim to 10%
    logging = false      -- set to 'true' to enable debug logging
})

-- Bind hotkey
dimmer:bindHotkeys({
    toggle = { {"shift", "cmd", "alt", "ctrl"}, "D" }
})
```

Above, I've set a hyperkey+D to toggle the dimmer on/off. The three configuration variables are optional (if not set here, the internal defaults are: 300 seconds inactivity timeout, dim to 10%, and debug logging on).

Tested with macOS Sequoia and Hammerspoon 1.0.0. Provided without guarantees (=use at your own risk).

MIT license.

