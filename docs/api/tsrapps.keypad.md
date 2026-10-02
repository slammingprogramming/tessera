# tsrapps.keypad

Package: `access-control`

keypad: a code lock for doors (the "piston door" idea from the old plans, and any redstone door).
  keypad setup      output, mode (pulse/toggle), open time, whether power CLOSES the door, and the code
  keypad run        show a keypad prompt; a right code operates the door, wrong codes lock it out for a while
The code is stored as a salted, iterated hash. Each wrong attempt doubles the lockout (10 s, 20 s, 40 s ... max 10 min).

## `M.lockout(failures)`

Lockout length in seconds after `failures` wrong codes in a row.

## `M.attempt(cfg, state, code, env)`

Try a code. state = { failures, locked_until } is updated. Returns "open", "wrong" or "locked" (+ seconds left).
