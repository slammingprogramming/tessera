# tsr.gfx.palette

Package: `gfx`

Colour palettes for advanced (colour) terminals and monitors. A scheme gives an RGB value to each of the 16 CraftOS colours;
the programs keep asking for colors.red and get the scheme's red. Applying works on a terminal object, so it also themes a
monitor. The choice is saved in the configuration key `ui.palette` and reapplied at boot.

## `M.apply(name, t)`

Apply scheme `name` to terminal `t` (default: the current one). Returns true or nil + reason.

## `M.reset(t)`

Back to the hardware defaults.

## `M.applySaved(t)`

The saved scheme (config ui.palette), if any, applied to `t`. Used at boot.

## `M.rgb(name, cname)`

RGB values (0-1 each) of a colour in the scheme, for previews.
