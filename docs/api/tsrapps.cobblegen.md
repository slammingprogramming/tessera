# tsrapps.cobblegen

Package: `cobblegen`

cobblegen: mine a regenerating block (a lava-and-water cobblestone generator) in front of the turtle.
  cobblegen [count] [--chest down|back|up] [--wait S]
Digs until `count` blocks were mined (default: forever). When only two inventory slots are free it empties into the
chest named by --chest, or stops if none was given (it never throws items on the ground). Put the turtle right in front of the generator's output block.

## `M.mineOnce(wait)`

Mine one block. Returns true when something was dug.

## `M.emptyOut(side)`

Empty everything into the chest on `side`; returns stacks dropped (0 when nothing could be dropped).
