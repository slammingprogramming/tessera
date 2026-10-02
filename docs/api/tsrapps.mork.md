# tsrapps.mork

Package: `game-mork`

MORK: a small text adventure in the tradition of the classic dungeon crawls. You wake in a cell under an old mine
and must find your way to the surface — ideally with the treasure. Type commands like "take torch", "go north",
"north", "open door", "read book", "attack zombie with sword", "inventory", "look", "score", "save", "load", "quit".
The engine is data-driven (see WORLD below); M.exec(state, line) is a pure function of the game state, which is how
the tests play the whole game.

## `M.exec(st, line)`

Execute one command line. Returns array of output lines; st.status becomes "won", "dead" or "quit" when it ends.
