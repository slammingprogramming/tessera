# tsrapps.build

Package: `build`

build: the building assistant. Places blocks from the turtle's inventory in shapes or from a blueprint file.
  build floor <length> <width> [block]        a flat rectangle
  build wall  <length> <height> [block]       a wall running to the right
  build box   <length> <width> <height> [block]   a hollow box (floor, walls and roof)
  build file  <blueprint> [--replace]         layers of characters, see below
  options: --yes (no question)  --nowait (stop instead of waiting for missing materials)
Coordinates: the structure starts one block IN FRONT of the turtle (f = 1..), extends to the right (r = 0.., including
the turtle's own column) and upward from the turtle's level (u = 0..). The turtle flies over the layer it is building
and places each block downward, bottom layer first, so it never gets walled in.

Blueprint files:
  # comments and blank lines are ignored
  legend                      (before the first layer)
  # = minecraft:stone_bricks       one "char = item" line per symbol; "." and space mean "nothing here"
  g = glass
  layer                       starts the next layer up (the first one is at the turtle's level)
  ###                         rows go away from the turtle (first row nearest), characters go to the right
  #g#

## `M.normalize(name)`

"stone" -> "minecraft:stone"; names that already contain a namespace are kept.

## `M.parseBlueprint(text)`

Parse blueprint text. Returns cells, or nil + error message (with the line number).
Comments (# ...) and the word "legend" are only allowed before the first layer, because "#" is a normal symbol
inside layers.

## `M.order(cells)`

Order cells layer by layer, each layer as a snake over rows (so the turtle wastes few moves).

## `M.materials(cells)`

Blocks needed: { [name] = count }.

## `M.run(ctx)`

Build the ordered cell list. ctx: name, params, cmd, cells, io, replace, nowait, stopAfter (test hook).
Returns true, "paused", or false + reason.

## `M.build(args, io, readFile)`

Turn arguments into a run context. Returns ctx or nil, error.
