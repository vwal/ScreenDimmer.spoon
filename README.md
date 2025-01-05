# macOS screen dimmer spoon

A Lua "spoon" script for **[Hammerspoon](https://www.hammerspoon.org/)** to dim MacBook Pro's internal screen and any external DDC-compatible monitors to a preset luminosity (10% by default) after a preset period of inactivity (5 minutes by default) has elapsed.

NOTE: This new version has been rewritten to use **[Lunar Pro](https://lunar.fyi/)** CLI utility, `lunar`. As a result, this script now supports all DDC-capable monitors. Some additional features have also been implemented, as outlined below. 

- The gamma mode ("subzero") is supported via Lunar's capability. `dimLevel` values 1-100 correspond to the hardware-based brightness, whereas values -1 through -100 correspond to the gamma shader values.
- The optional `internalDisplayGainLevel` sets the MacBook Pro's internal display to a different dimness level from the external monitor(s). You can define a positive or negative value. However, a positive value is usually used because the internal display tends to appear darker than external monitors at the same `dimLevel`.
- Optional `displayPriorities` can be defined to change the default order in which the displays are dimmed and restored. The sequence happens quickly, but you may nevertheless want your primary monitor dimmed/restored first.
- Automatic handling of connected/disconnected monitors without having to reload the spoon.

I use this script when I don't want to use the screen saver and/or screen sleep, but I also don't want to keep the screen at normal brightness when I don't actively use the system. The original brightness is restored upon the first user interaction (keyboard/mouse/trackpad). The script handles brightness restoration correctly after the screen saver, lock screen, and screen sleep.

### Installation

First, make sure you have Lunar Pro installed and then select from its toolbar menu: `Advanced Features` → `Install CLI integration`. This will install the `lunar` CLI utility at `~/.local/bin/lunar`

If you don't want to use Lunar Pro's CLI utility, switch to the `m1ddc-based` branch (after cloning the repository as outlined below, change to the `ScreenDimmer.spoon` directory and execute `git checkout --track origin/m1ddc-based`. This branch works with `m1ddc,` a FOSS utility (install with `brew install m1ddc`). Note: The old `m1ddc-based` version works fine but has fewer features and doesn't support as many DDC-capable monitors (see README.md in that branch for further details).

Make sure you have [Hammerspoon](https://www.hammerspoon.org/) installed, then clone this repository:

```shell
cd ~/.hammerspoon
mkdir Spoons
cd Spoons
git clone https://github.com/vwal/ScreenDimmer.spoon.git
```

The ScreenDimmer will appear as `ScreenDimmer.spoon` directory (as Hammerspoon requires). 

Call/initialize ScreenDimmer from `~/.hammerspoon/init.lua` as shown below:

```
-- Load ScreenDimmer Spoon
local dimmer = hs.loadSpoon("ScreenDimmer")

-- Configure the Spoon
dimmer:configure({
    idleTimeout = 300,  -- 5 minutes in seconds, adjust as needed
    dimLevel = -75,     -- negative values use "subzero", i.e. gamma shader
    logging = false,    -- set to `true` for debug logging
    lunarPath = "~/.local/bin/lunar", -- optional variable to set the location of the `lunar`
                                      -- CLI command if it's at a non-standard location
    internalDisplayGainLevel = 50,    -- optional variable to dim the internal display to
                                      -- a different level than what is set with `dimLevel`.
                                      -- In this example to -25.
    displayPriorities = {  -- example optional monitor priorities to alter the default
                           -- order of brightness adjustment; get your monitor names
                           -- with `lunar displays`
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

Above, I've set a hyperkey+D to toggle the dimmer on/off and ⇧⎇⌘+D to dim the screen(s) immediately (note: you can define both, either or no hotkeys). If no hotkeys are defined when calling ScreenDimmer, none are set internally.

Tested with macOS Sequoia and Hammerspoon 1.0.0. Provided without guarantees (= use at your own risk).

MIT license.

