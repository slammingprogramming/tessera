# tsr.games.g2048

Package: `games`

2048. Slide with the arrow keys (or WASD); equal tiles merge. R restarts, Q quits.

## `M.move(board, dir)`

Move the board in `dir` ("left", "right", "up", "down"). Returns newBoard, pointsGained, moved (without touching the old board).

## `M.spawn(board, rng)`

Add a 2 (90%) or 4 (10%) on a random empty cell. rng(n) returns 1..n. Returns true when a tile was added.

## `M.play(g, dir)`

Play a move on a game. Returns true when the board changed.
