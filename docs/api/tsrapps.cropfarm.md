# tsrapps.cropfarm

Package: `cropfarm`

cropfarm: harvest and replant a rectangular crop field, only touching ripe plants.
  cropfarm <length> <width> [--crop wheat|carrots|potatoes|beetroots|nether_wart] [--chest down|back|up|none]
           [--keep N] [--interval S] [--once]
Setup: stand ABOVE the field's near-left corner (crops are one block below the turtle's flight level), facing along
the field's length. Seeds go anywhere in the inventory. A chest below the start (default), behind it or above it
receives the harvest. --crop lets it fill empty patches; without it only ripe plants are replaced.

## `M.tend(cropName)`

Harvest a ripe crop below and replant it. Returns "harvested", "growing", "empty" or "other".

## `M.dump(side, keepSeeds)`

Empty the inventory into a chest, keeping up to `keepSeeds` seeds for replanting.

## `M.harvest(length, width, opts, io)`

One full pass over the field. Returns a table of counts.
