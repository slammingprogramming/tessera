# tsrapps.guard

Package: `guard`

guard: a turtle with a sword that attacks whatever comes near.
  guard [--sides f,u,d] [--turn] [--pickup] [--rest S] [--rounds N]
Each round it attacks every chosen side (f = front, u = up, d = down). --turn rotates a quarter turn after each round
so all four directions get covered; --pickup collects the drops with suck. Runs until Ctrl+T (or N rounds).

## `M.parseSides(text)`

Parse "f,u,d" into an ordered list of side letters, or nil + error.

## `M.round(sides, pickup)`

One round of attacks. Returns the number of hits.
