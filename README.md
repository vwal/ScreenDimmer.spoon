# ScreenDimmer.spoon

A Hammerspoon Spoon that dims displays after inactivity using hybrid hardware + gamma dimming. Requires [Lunar Pro](https://lunar.fyi/) for hardware brightness control.

## How it works

ScreenDimmer uses a two-stage dimming approach:

1. **Hardware brightness** is reduced to a configurable minimum via Lunar CLI (reduces backlight power and thermal output)
2. **Gamma overlay** (`hs.screen:setGamma()`) smoothly fades the image at ~30fps on all displays, including the built-in display

On restore, gamma fades back first (instant visual feedback), then hardware brightness is restored via Lunar. The result is a smooth, flicker-free dim/restore cycle.

## Requirements

- [Hammerspoon](https://www.hammerspoon.org/)
- [Lunar Pro](https://lunar.fyi/) with CLI installed at `~/.local/bin/lunar`
- macOS Accessibility permissions (Hammerspoon will prompt on first run)

## Installation

Copy `ScreenDimmer.spoon` to `~/.hammerspoon/Spoons/`, then add to your `~/.hammerspoon/init.lua`:

```lua
local dimmer = hs.loadSpoon("ScreenDimmer")
dimmer:configure({
    idleTimeout = 300,
}):start()

dimmer:bindHotkeys({
    toggle = { {"shift", "cmd", "alt", "ctrl"}, "d" },
    dim    = { {"shift", "cmd", "alt"}, "d" },
    reset  = { {"shift", "cmd", "alt", "ctrl"}, "r" },
})
```

## Per-display configuration

Each display can be configured independently by UUID. To find your display UUIDs, run in the Hammerspoon console:

```lua
spoon.ScreenDimmer:listDisplays()
```

This prints a ready-to-paste config snippet. Example:

```lua
dimmer:configure({
    idleTimeout      = 300,
    internalDimLevel = -30,
    externalDimLevel = -80,
    displays = {
        ["AE130EBE-19FD-4E7D-9656-87383697B7B7"] = dimmer:display(-80, 1),     -- BenQ (primary)
        ["37D8832A-2D66-02CA-B9F7-8F30A301B230"] = dimmer:display(-30, 2),     -- Built-in
        ["7FECA4AA-F754-4550-999E-93893C69C551"] = dimmer:display(-80, 3),     -- LG 1
        ["48DD49F4-9D6C-45C6-B4B8-3D802434E089"] = dimmer:display(-80, 4, 2), -- LG 2, minBrightness 2
    },
}):start()
```

The `display()` helper accepts: `dimmer:display(dimLevel, priority, minBrightness)`

- **dimLevel** — target dim level (see scale below)
- **priority** — display order (lower = higher priority, for logging)
- **minBrightness** *(optional)* — override the minimum hardware brightness for this display

## Dim level scale

| Range | Behavior |
|-------|----------|
| **1 to 100** | Hardware brightness target only (no gamma overlay) |
| **0** | Hardware brightness at configured minimum, no gamma |
| **-1 to -100** | Hardware brightness at minimum + gamma overlay dimming |

For negative values, the gamma whitepoint is calculated as:

```
whitepoint = (100 + dimLevel) / 100
```

| dimLevel | Hardware | Gamma whitepoint | Effect |
|----------|----------|-----------------|--------|
| -30 | minimum | 0.70 | Light dim |
| -50 | minimum | 0.50 | Moderate dim |
| -80 | minimum | 0.20 | Deep dim |
| -99 | minimum | 0.01 | Near black |

## Configuration reference

All parameters are optional — defaults are applied for any value not specified.

### Core

| Parameter | Default | Description |
|-----------|---------|-------------|
| `idleTimeout` | `300` | Seconds of inactivity before dimming |
| `fadeDuration` | `1.0` | Seconds for the gamma fade animation |
| `fadeInterval` | `0.033` | Seconds between gamma updates (~30fps) |
| `checkInterval` | `5` | Seconds between idle time checks |
| `lunarPath` | `~/.local/bin/lunar` | Path to Lunar CLI binary |
| `logging` | `true` | Enable console logging |

### Dim levels

| Parameter | Default | Description |
|-----------|---------|-------------|
| `internalDimLevel` | `-30` | Default dim level for built-in display |
| `externalDimLevel` | `-80` | Default dim level for external displays |
| `internalMinBrightness` | `2` | Minimum hardware brightness for built-in display |
| `externalMinBrightness` | `1` | Minimum hardware brightness for external displays |

### Safety and recovery

| Parameter | Default | Description |
|-----------|---------|-------------|
| `stuckTimeout` | `30` | Force-reset if stuck in dimming/restoring for this many seconds. `0` to disable |
| `verifyDelay` | `1` | Seconds to wait after restore before verifying brightness |
| `verifyRetries` | `2` | Max retry attempts if brightness doesn't match expected value |
| `verifyTolerance` | `2` | Acceptable brightness deviation (±) during verification |
| `screenChangeDebounce` | `2` | Seconds to wait for display add/remove events to settle |
| `screenChangePollInterval` | `1` | Seconds between Lunar readiness checks after displays change |
| `screenChangePollTimeout` | `20` | Give up display-change recovery after this many seconds |
| `screenChangeIdleCooldown` | `10` | Suppress automatic re-dimming briefly after display changes |
| `screenChangeDefaultBrightness` | `70` | Fallback brightness for newly seen displays with no remembered state |
| `rememberBrightStates` | `true` | Persist last known bright brightness per display UUID |
| `settingsKey` | `"ScreenDimmer.lastBrightState"` | `hs.settings` key used for persisted bright-state memory |

### Wake sequence

| Parameter | Default | Description |
|-----------|---------|-------------|
| `wakeDelay` | `2` | Seconds to wait after wake before polling Lunar |
| `wakePollInterval` | `1` | Seconds between Lunar readiness checks after wake |
| `wakePollTimeout` | `15` | Give up polling and force-reset after this many seconds |

### Lunar health monitoring

| Parameter | Default | Description |
|-----------|---------|-------------|
| `lunarHealthInterval` | `30` | Seconds between health checks. `0` to disable |
| `lunarRestartCooldown` | `120` | Minimum seconds between auto-restart attempts |
| `lunarAppName` | `"Lunar"` | App name used for `open -a` when restarting |

### Screensaver

| Parameter | Default | Description |
|-----------|---------|-------------|
| `screensaverCooldown` | `3` | Seconds to ignore input events after screensaver start/stop |

### Per-display overrides

| Parameter | Default | Description |
|-----------|---------|-------------|
| `displays` | `{}` | Table of per-display overrides, keyed by UUID |

## Hotkeys

Bind with `dimmer:bindHotkeys(mapping)`:

| Action | Description |
|--------|-------------|
| `toggle` | Enable or disable ScreenDimmer |
| `dim` | Immediately dim or restore (toggle) |
| `reset` | Emergency force-reset: cancel all fades, restore gamma and hardware brightness |

Example:

```lua
dimmer:bindHotkeys({
    toggle = { {"shift", "cmd", "alt", "ctrl"}, "d" },
    dim    = { {"shift", "cmd", "alt"}, "d" },
    reset  = { {"shift", "cmd", "alt", "ctrl"}, "r" },
})
```

## API methods

| Method | Description |
|--------|-------------|
| `configure(config)` | Set configuration (merged with defaults) |
| `start()` | Enable dimming and start all watchers |
| `stop()` | Disable dimming, restore displays, stop watchers |
| `toggle()` | Toggle between started and stopped |
| `dimNow()` | Immediately dim or restore displays |
| `bindHotkeys(mapping)` | Bind keyboard shortcuts |
| `listDisplays()` | Print connected displays with UUIDs and a config snippet |
| `display(dimLevel, priority, minBrightness)` | Helper to create per-display config entries |
| `forceReset()` | Emergency reset: cancel fades, restore everything, reset state |

## Event handling

ScreenDimmer automatically handles:

- **System sleep/wake** — polls Lunar for readiness before restoring after wake
- **Screen lock/unlock** — restores on unlock, cancels fades on lock
- **Screensaver start/stop** — restores brightness when screensaver starts (so monitors don't power down while dimmed), pauses idle checking while active
- **Screen configuration changes** — debounces add/remove events, waits for Lunar to see active displays, then restores each display to its last known bright brightness or the configured fallback
- **Lunar crash** — detects unresponsive Lunar and auto-restarts it

## License

MIT
