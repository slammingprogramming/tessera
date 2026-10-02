# tsrapps.treefarm

Package: `treefarm`

treefarm: a self-running tree farm. Rebuilt from the old treefarm script (same idea: wait for the tree in front,
chop it, replant, dump the wood, keep fuelled) with item-name matching instead of fixed slots, any wood type, and
fuel taken from the logs it chops.
  treefarm [--chest down|back|up|none] [--fuel N] [--wait S] [--once]
Setup: put the turtle facing the spot where a sapling grows (dirt or grass underneath), saplings anywhere in its
inventory, and a chest below it (default), behind it (--chest back) or above it (--chest up).

## `M.treeAhead()`

Is a mature tree standing in front of the turtle?

## `M.chop()`

Fell the tree in front (climbing the trunk), then come back down. Returns the number of logs cut.

## `M.replant()`

Plant a sapling in front. Returns true or false + reason.

## `M.dump(side)`

Empty everything except saplings and fuel into the chest on `side`.

## `M.cycle(opts, io)`

One pass: refuel if needed, fell a waiting tree, replant, dump. Returns "waiting" or a summary table.
