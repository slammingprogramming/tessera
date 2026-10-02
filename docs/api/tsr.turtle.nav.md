# tsr.turtle.nav

Package: `turtle-core`

Turtle navigation with A* pathfinding and obstacle memory.

  local nav = require("tsr.turtle.nav")
  nav.goto(10, 0, -4)                 -- walk there around anything in the way, learning obstacles as it bumps into them
  nav.goto(x, y, z, { dig = true })   -- when no way around exists, dig through

The turtle plans over its map: cells it knows to be blocked are avoided, unknown cells are assumed free (the plan is
optimistic and gets corrected as the turtle meets real blocks). Blocked cells it only *failed to enter* (a mob, falling
gravel) are forgotten after FORGET_SECONDS; cells it saw with `detect` are kept until they are seen open again.
Coordinates are tsr.turtle's: x east, y up, z south.

## `N.reset()`

Forget everything (tests, or after the world changed a lot).

## `N.markBlocked(x, y, z, solid)`

Remember that a cell is blocked (solid = true: seen with detect; false: merely could not be entered).

## `N.plan(x1, y1, z1, x2, y2, z2, opts)`

Shortest path from (x1,y1,z1) to (x2,y2,z2) over cells not known to be blocked. Returns an array of cells
({x,y,z}, excluding the start, including the goal) or nil + reason. opts.margin: how far outside the box spanned by start
and goal the search may wander (default 12), opts.avoid(x,y,z) -> true to treat extra cells as blocked.

## `N.observe()`

Look ahead, up and down and remember solid blocks. Returns nothing.

## `N.goto(x, y, z, opts)`

Walk to (x, y, z). opts: dig (dig through when no way around is known), maxReplans, fuelMargin.
Returns true, or false + reason ("no path", "out of fuel", "too many obstacles", "blocked").
