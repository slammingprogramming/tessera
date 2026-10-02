# tsr.craftcli

Package: `craft`

The autocraft command (named so that it does not hide the stock `craft`; crafty turtle with a crafting table). Commands:
  autocraft <item> [count] [--stash down|up|front] [--source up|down|front]     make items (and what they are made of)
  autocraft plan <item> [count]                                                 show what would be crafted and what is missing
  autocraft list [text]                                                         craftable items          autocraft learn [--shapeless]   teach a recipe
  autocraft forget <item>                                                       remove a learned recipe
The stash is a chest next to the turtle (default: below) where ingredients wait and finished items land; the optional source chest is
emptied into the stash first. Put materials into the stash, run `autocraft furnace`, collect the furnace from the stash.

## `M.itemName(db, text)`

"furnace" -> "minecraft:furnace"; a unique partial name also works. Returns the full name or nil + reason.
