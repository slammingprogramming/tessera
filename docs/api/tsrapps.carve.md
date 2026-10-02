# tsrapps.carve

Package: `carve`

carve: dig out a room. Successor of the old makeroom ("carveroom") script: same idea — length, width, height,
from the corner or centred on the turtle, with an offset — but crash-safe and resumable.
  carve [length] [width] [height] [--center] [--offset f,r,u] [--dump back|down|up] [--junk] [--stay] [--yes]
Without --center the room extends forward and to the right (including the turtle's own column) and upward from the
turtle's level. --center puts the turtle in the middle of the floor. --offset shifts the whole room (forward, right, up).

## `M.bounds(length, width, height, center, of, or_, ou)`

Region bounds for a room: returns f0, f1, r0, r1, u0, u1.
