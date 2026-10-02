# tsr.gui.theme

Package: `ui-gui`

Colour themes for the desktop. A theme maps semantic roles (what a colour is FOR) to CraftOS colours, so widgets never name a
concrete colour. "mono" only uses the four greys a basic computer can show.

## `M.resolve(name, isColor)`

The theme a terminal can show: colour terminals get `name` (default dark); grey-scale ones always get mono.
