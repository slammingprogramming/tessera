# tsrapps.bore

Package: `bore`

bore: dig a tunnel. Successor of the old maketunnel script (which also had configuration, torches, cleaning and
save/resume) — now built on the shared excavation engine, so it survives reboots and chunk unloads properly.
  bore [length] [width] [height] [--torch N | --no-torch] [--dump back|down|up] [--junk] [--stay] [--yes]
The tunnel starts in front of the turtle; it is `width` wide to the right (starting with the turtle's own column)
and `height` tall from the turtle's level up. Put torches in the inventory for automatic lighting.

## `M.build(args, io, hasTorches)`

Turn command-line arguments (plus prompts for missing sizes) into an engine context. Returns ctx or nil, error.
