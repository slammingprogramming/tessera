# tsr.craft

Package: `craft`

The crafting turtle: give it a recipe database and ingredients and it crafts items, including everything the item is made of.

How a turtle crafts (ComputerCraft): with a crafting table equipped, `turtle.craft(n)` reads the turtle's inventory as a 3x3 grid
(slots 1 2 3 / 5 6 7 / 9 10 11), requires every OTHER slot to be empty, crafts up to n times and stores the result starting at the
selected slot. So this module works with a STASH chest (default: below the turtle) as the place where everything that is not part of
the current craft waits:  park all -> pull exactly the ingredients into their grid cells -> craft -> park the result.
Optionally a SOURCE chest (e.g. above) is emptied into the stash first, so you can throw materials into one chest and ask for items.

Recipes: files in /usr/share/recipes (shipped) and /etc/tsr/recipes.d (yours, e.g. made with `autocraft learn` for modded items):
  return { tags = { planks = { "_planks$" } },
           recipes = { { out = "minecraft:stick", count = 4, shape = { "P", "P" }, key = { P = "#planks" } },
                       { out = "minecraft:torch", count = 4, shapeless = { "minecraft:coal", "minecraft:stick" } } } }
An ingredient is an exact item name, "#tag" (any item whose name matches one of the tag's Lua patterns or lists), or { any = { ... } }.

## `M.normalize(r)`

Normalise one recipe: cells[1..9] = ingredient spec | nil (shaped recipes are placed at the top left), or a shapeless list.

## `M.load(dirs)`

Load recipes from `dirs` (default M.DIRS). Returns db = { recipes = { [item] = { recipe, ... } }, tags = { name = { patterns } } }.

## `M.add(db, doc, source)`

Merge a recipe document ({ tags, recipes }) into a database.

## `M.matches(db, spec, name)`

Does an ingredient spec accept the item called `name`?

## `M.plan(db, item, count, have)`

Plan how to make `count` of `item` from the stock `have` ({ [item] = n }). Returns steps, missing where
steps = list of { out, recipe, times, picks = { [specText] = concrete item name } } in the order to execute, and
missing = { [spec text] = n } of raw materials that are not available. `have` is not modified.

## `M.scan(env)`

Items in the turtle: { [name] = count }, plus the list of occupied slots.

## `M.park(env, only)`

Move every item out of the turtle into the stash chest. Returns true or nil + reason.

## `M.stock(env)`

Take everything from the source chest into the stash chest (so ingredients can be found there). Returns the number of stacks moved.

## `M.craftStep(db, env, step)`

Run one crafting step: `times` crafts of recipe `r` (an entry of a plan). Returns true or nil + reason.

## `M.make(item, count, env)`

Make `count` of `item`. env: turtle (default the global), stash ("down" default), source (chest to take materials from), db, log(text).
Everything the turtle carries and everything in the stash counts as stock; the finished items end up in the stash.
Returns true, or nil + reason (with the missing raw materials in the text).

## `M.inspectStash(env)`

What is in the stash, as { [name] = count }: take the stacks out one by one, count them and put them back.

## `M.learn(env, opts)`

Record the recipe that is currently laid out in the grid by crafting it once. opts: shapeless (bool). Returns the recipe document
({ tags = {}, recipes = { r } }) or nil + reason. The crafted items stay in the turtle.

## `M.serialize(doc)`

Serialise a learned recipe document into a Lua file's text.
