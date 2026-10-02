# tsr.shop

Package: `shop`

A vending shop built from chests.
  input   a chest next to the computer where customers drop the currency item (it stays there as their balance)
  till    where payments go (your income)       output   where purchased goods appear (the customer takes them)
  stock   one or more chests holding the goods
  monitor optional: lists the goods; tap one to buy it. Without a monitor the terminal is used (keys 1-9, R = refund).
Configuration /etc/tsr/shop.cfg (edit with the `shop` command):
  { name = "Spawn Shop", currency = "minecraft:diamond", input = "chest_0", till = "chest_1", output = "chest_2",
    stock = { "chest_3", "chest_4" }, monitor = "monitor_0",
    items = { { id = "minecraft:iron_ingot", label = "Iron x8", price = 1, per = 8 } } }
Every price is in whole currency items; `per` is how many goods one purchase gives.

## `M.new(cfg, env)`

env (all optional, for tests): peripheral, clock (function -> text), logPath

## `Shop:check()`

Check that every configured chest exists. Returns true or nil + list of problems.

## `Shop:balance()`

How much currency the customer has put in.

## `Shop:stock(id)`

How many of `id` the stock chests hold.

## `Shop:buy(index, qty)`

Sell `qty` purchases of item number `index`. Returns true + message, or false + reason (nothing is lost in either case).

## `Shop:refund()`

Give the remaining balance back through the output chest. Returns the amount returned.

## `Shop:draw(t)`

Draw on terminal `t`. Returns the screen rows of each item: { [row] = itemIndex } and the refund row.

## `M.run(cfg, env)`

The shop loop. env: term (default current or the configured monitor), maxEvents (tests).

## `M.cli(args, io, env)`

shop status | set <input|till|output|currency|monitor|name> <value> | stock add|remove <chest> |
     add <item id> <price> [per] [label] | remove <n> | run

## `M.daemon()`

The shopd service.
