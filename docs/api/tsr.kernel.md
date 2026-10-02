# tsr.kernel

Package: `core`

Tessera kernel: cooperative process scheduler + event router.

Processes are coroutines. Each gets its own terminal window (multishell-style); the kernel redirects `term` to the
process' window while it runs. Input events (keyboard/mouse/paste/terminate) go only to the focused process, every
other event is broadcast to processes whose filter matches — exactly the contract of os.pullEvent, so unmodified
CraftOS programs run under it. There is no preemption in CC:T; a process that never yields is killed by CC itself.

## `K.init(opts)`

Set the terminal the kernel draws on (default: the current terminal). Call before spawning processes.

## `K.reset()`

Kill everything and reset all kernel state (tests, recovery).

## `K.spawn(spec)`

Start a process. spec fields:
  name (string), fn (function) | path (string, a Lua file), args (array),
  window (default true; false = share the root terminal), term (use this terminal object instead of a window),
  focus (bool: take input focus), session (bool: reachable with Alt+<n>), env (extra globals for `path` programs)
Returns pid, process   (or nil, error when `path` cannot be loaded).

## `K.list()`

Snapshot of the process table.

## `K.terminate(pid)`

Deliver a terminate event (polite; the process may ignore it).

## `K.kill(pid)`

Kill a process immediately (no cleanup runs).

## `K.wait(pid)`

Block (from inside a process) until `pid` exits. Returns ok, err of the process.

## `K.hotkey(combo, fn)`

Bind a global hotkey, e.g. K.hotkey("alt+q", fn). The key event is consumed when a hotkey fires.

## `K.send(pid, ...)`

Hand an event straight to one process (honouring its event filter), whether or not it has the focus. Used by window
managers to forward translated mouse and keyboard events to the program inside a window. Returns false when `pid` is gone.

## `K.onStop(fn)`

Register a function to run when the kernel stops (before processes are killed).

## `K.stop(action)`

Ask the main loop to end. action: "craftos" (return to plain CraftOS), "shutdown" or "reboot".

## `K.run()`

Run the scheduler until every process has exited or K.stop() is called. Returns the exit action.
