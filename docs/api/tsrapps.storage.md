# tsrapps.storage

Package: `svc-storage`

storage: manage a network of chests (or any inventory: barrels, drawers, modded storage) connected by wired modems.
  storage scan                      what is stored where (totals per item)
  storage find <pattern>            where an item is
  storage get <pattern> <count> <inventory>    move items into an inventory (e.g. a chest next to you)
  storage sort [--once] [--interval S]         empty the input inventory into the right chests by the rules
  storage input <inventory> | overflow <inventory>            set the input chest / where unmatched items go
  storage rule add <pattern> <inventory> | list | remove <n>   sorting rules, first match wins
Patterns: exact item name ("minecraft:coal"), "minecraft:*_ore", "*log", or a Lua pattern with the prefix re:
Uses only the generic `inventory` peripheral methods (list, size, pushItems), so it works with any mod's storage.

## `M.matches(pattern, name)`

Does `name` match `pattern`? ("re:" prefix = Lua pattern, "*" wildcards otherwise)

## `M.inventories(env)`

Names of inventory peripherals on the network.

## `M.scan(env, exclude)`

Index of everything stored: { items = { name = { total, at = { {inv, slot, count} } } }, free = { inv = slots }, slots }

## `M.find(index, pattern)`

Find item names matching a pattern. Returns sorted array of { name, total }.

## `M.get(env, pattern, count, dest)`

Move up to `count` of items matching `pattern` into `dest`. Returns the number moved.

## `M.destination(cfg, itemName)`

The destination inventory for an item under the rules (or overflow), or nil.

## `M.sortOnce(cfg, env)`

One sorting pass over the input inventory. Returns { moved = n, stuck = n, by = { [inventory] = n } }.
