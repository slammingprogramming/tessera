# tsr.turtle

Package: `turtle-core`

tsr.turtle: the foundation every Tessera turtle program builds on.

 * Position and heading are tracked in a coordinate frame that starts at (0,0,0) facing "north" (dir 0), unless
   GPS calibration gives absolute coordinates. x grows east, y up, z south. dir: 0 north (-z), 1 east, 2 south, 3 west.
 * The state is persisted with a write-ahead journal (two alternating slot files), so a turtle that is unloaded
   mid-move still knows where it is after it restarts: an unfinished move is resolved by comparing the fuel level.
 * dig-and-move handles gravel, entities and unbreakable blocks; goto() walks to coordinates.
 * Frames give jobs coordinates relative to where they started (forward / right / up).
 * Fuel and inventory helpers, and a small job store so long jobs can be resumed after a reboot.

## `M.load()`

Load the saved state (once). An interrupted move is settled by the fuel level: fuel drops by one per move.
Turns cannot be checked, so an interrupted turn is assumed to have happened (see M.calibrate to re-sync).

## `M.reset(x, y, z, dir)`

Forget everything and start a new frame here: (x, y, z) facing dir (default 0,0,0 facing north).

## `M.unloadForTest()`

Test hook: drop the in-memory copy so the next call reloads from disk.

## `M.face(dir)`

Turn to face `dir` (0..3) by the shortest route.

## `M.call(side, what, ...)`

Call the turtle API function for a side: M.call("u", "dig") == turtle.digUp().

## `M.digMove(side, opts)`

Clear the way on `side` ("f", "u" or "d") — digging (gravel keeps falling) and fighting whatever blocks — and move.
opts.tries (default 40). Returns true, or false + reason ("Out of fuel", "blocked by an unbreakable block", ...).

## `M.goto(x, y, z, opts)`

Move to (x, y, z) in the current frame. opts.dig (bool: dig through obstacles), opts.order (default "yxz").
Returns true, or false + reason.

## `M.distanceTo(x, y, z)`

Manhattan distance from the current position to a point (fuel estimate for goto).

## `M.frame(origin)`

A local coordinate system anchored at `origin` ({x,y,z,dir}, default: the turtle's current spot and heading):
f = blocks forward, r = blocks to the right, u = blocks up. Jobs plan in these terms, so they work whichever way
the turtle happens to face and can be resumed after a restart by saving `frame.origin`.

## `M.calibrate(timeout)`

Adopt absolute GPS coordinates and work out the heading by stepping once. Needs a modem and a GPS constellation.
Returns true, or false + reason. The turtle ends where it started.

## `M.matcher(spec)`

A matcher from a spec: exact item name, "prefix*", a table of names, or a function(detail).

## `M.ensureFuel(needed, opts)`

Make sure at least `needed` fuel is available, burning fuel items from the inventory if necessary.
opts.keep = { [slot] = true } protects slots. Returns true, or false + reason.

## `M.slotOf(spec)`

First slot holding an item that matches `spec`, or nil.

## `M.selectItem(spec)`

Select a slot holding `spec`. Returns the slot or nil.

## `M.dump(side, keepSlots, keepSpec)`

Drop everything except slots in keepSlots (set) and items matching `keepSpec` into the inventory on `side`.
Returns the number of item stacks dropped.

## `job.begin(name, params, cmd)`

Start recording a job: name, params (any JSON-able table), cmd = { program, args... } used to resume it.

## `job.update(progress)`

Merge `progress` into the saved job (atomic write).

## `job.resumable(name, params)`

Convenience for apps: returns the saved job when it is `name` and was started with the same params, so a re-run of
the same command continues instead of starting over.
