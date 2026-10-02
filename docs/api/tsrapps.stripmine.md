# tsrapps.stripmine

Package: `stripmine`

stripmine: a main shaft with side branches — the classic way to find ore.
  stripmine [length] [--spacing N] [--branch N] [--dump back|down|up] [--junk] [--stay] [--yes]
Tunnels are 1 wide and 2 high. Every `spacing` blocks (default 3, so two blocks of rock stay between branches) a branch
of `branch` blocks (default 8) is dug to both sides. Put a chest behind the start and use --dump back to keep going.

## `M.plan(length, spacing, branch)`

The cell sequence for a strip mine. Every step moves to a neighbouring cell, so the turtle only ever walks through
tunnels it has already dug.
