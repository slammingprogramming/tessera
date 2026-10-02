# tsr.sandbox

Package: `sandbox`

Sandbox: run a Lua program with a restricted view of the computer.

  local sb = require("tsr.sandbox")
  local ok, result = sb.run("/downloads/game.lua", { root = "/var/sandbox/game", timeout = 5, args = { "easy" } })

What the program gets
  * a copy of the safe standard library (string, table, math, coroutine, bit32, utf8) and of textutils/colors/keys/vector
  * a file system that shows only `root` as "/" (writes outside it are impossible) plus a read-only /rom
  * the terminal, os.clock/time/epoch/pullEvent/sleep, but NOT os.shutdown/reboot/run, io, debug, http, peripherals, rednet,
    redstone, shell or the global table of the real system (unless opts.allow says so)
  * a CPU limit (`timeout` seconds of running time, the program may wait for events for as long as it likes) and a memory limit
What it is NOT: a hard security boundary against someone who finds a hole in CC itself. It stops mistakes and the usual
malicious tricks (deleting files, shutting down, stealing the network, endless loops), nothing more. Known gaps: string
methods such as ("x"):rep(1e9) and pathological Lua patterns run in native code that the instruction hook cannot interrupt, so
a program can still make the computer sluggish or run it out of memory that way; give untrusted code a window of its own and
watch it.

## `M.jail(root, opts)`

A file system API whose "/" is the real folder `root` (created if needed). opts.quota: bytes the jail may hold (default
200000). "/rom" is the real, read-only rom.

## `M.environment(opts)`

Build the environment. opts: guard ({ hook = function, violation = function -> text|nil }, set by run), fs (jail API), allow = { peripheral = bool, http = bool, rednet = bool, redstone = bool, os = bool,
shell = table }, env (extra globals).
