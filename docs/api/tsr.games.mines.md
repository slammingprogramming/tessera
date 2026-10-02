# tsr.games.mines

Package: `games`

Minesweeper. Left click (or Space) opens a square, right click (or F) plants a flag, arrows move the cursor, Q quits.
The first square you open is always safe.

## `M.new(w, h, mines, rng)`

A new game. rng(n) returns 1..n.

## `M.open(g, x, y)`

Open a square (flood-filling empty areas). Returns "ok", "boom", "won" or "ignored".

## `M.chord(g, x, y)`

Open all neighbours of a satisfied number ("chording"). Returns the list of results.
