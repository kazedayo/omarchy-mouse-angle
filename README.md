# omarchy-mouse-angle

Per-mouse sensor angle for the [Omarchy](https://omarchy.org/) bar: rotates a
mouse's pointer input by whole degrees via Hyprland/libinput device rotation —
the driver setting vendors gate behind Windows software, for any mouse.

![panel](screenshot.png)

## Install

Requires Omarchy (Hyprland >= 0.56, Lua config).

```sh
git clone https://github.com/kazedayo/omarchy-mouse-angle \
  ~/.config/omarchy/plugins/io.github.kaz.omarchy-mouse-angle

omarchy bar put io.github.kaz.omarchy-mouse-angle --section right
omarchy restart shell
```

Add to `~/.config/hypr/hyprland.lua`, then `hyprctl reload`:

```lua
local require_optional = require("default.hypr.require_optional")
require_optional.module("hypr.mouse-angle")
```

## Usage

Click the bar glyph: pick a mouse, then adjust with the buttons, slider, or
arrow keys. Degrees are clockwise, 0–359 — 353 is 7 degrees anticlockwise.
Settings apply immediately and persist to the generated
`~/.config/hypr/mouse-angle.lua` (edit by hand, then `hyprctl reload`).

## Development

`node test_model.js` runs the logic tests. MIT.
