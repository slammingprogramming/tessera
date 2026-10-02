# tsr.games.snake

Package: `games`

Snake. Arrow keys or WASD steer, Q quits. Eat food to grow; walls and your own tail end the game.

## `M.new(w, h, rng)`

A new game on a w x h board. rng(n) returns an integer from 1 to n (default math.random).

## `M.placeFood(g)`

Put the food on a random free cell. Returns false when the board is full.

## `M.turn(g, dir)`

Change direction (a 180-degree turn is ignored). The change takes effect at the next step.

## `M.step(g)`

Advance one step. Returns "ate", "moved", "dead" or "won".

## `M.delay(g)`

Seconds between steps: faster as the score grows.

## `M.run(env)`

Play. env: term, rng, maxSteps (tests), events (function returning the next event, tests).
