# tsrapps.excavate

Package: `excavate`

Excavation engine shared by bore (tunnels), carve (rooms), stripmine and quarry.

A job is a list of cells in *local* coordinates (f forward, r right, u up, relative to where the turtle started),
ordered so that consecutive cells are neighbours (a "snake" walk, so the turtle never backtracks over solid rock).
The runner walks the list, digging into each cell; it refuels, empties its inventory into a chest (or waits for the
player), places torches, saves its progress every few cells and — because the frame origin is saved too — carries on
from where it stopped if the turtle is rebooted or unloaded.

## `E.snake(A, B, C)`

Snake (boustrophedon) order over an A x B x C grid: yields {a, b, c} zero-based, every step changing one index by 1.

## `E.plan(spec)`

Cells of a box. spec: f0,f1,r0,r1,u0,u1 (inclusive local ranges), order "slices" (walk forward slice by slice; good
for tunnels) or "layers" (level by level; good for rooms and pits), udown (visit layers top to bottom).
Returns array of { f, r, u, s = slice index, last = true on a slice's final cell }.

## `E.contiguous(cells)`

Every consecutive pair of cells must be neighbours; returns true or false + index of the first gap (for tests).

## `E.fuelEstimate(cells)`

Rough fuel needed: one move per cell, some slack for detours and the way home.

## `E.run(ctx)`

Run (or resume) a job.
ctx: name, params (JSON-able, identifies the job for resume), cmd ({program, args...} to restart it),
     cells, io, torch = {every, item}, dump ("back"|"down"|"up"), junk, stay, keepItems (item spec kept when dumping),
     stopAfter (test hook: pause after that many cells), save (cells between progress saves, default 8)
Returns true when finished, "paused" (test hook), or false + reason.
