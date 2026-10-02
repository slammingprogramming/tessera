# tsr.shell.capture

Package: `shell`

Output capture and input feeding for pipes and redirects.
  capture.new()  -> a terminal-shaped object that records what a program prints, as text
  capture.stdin(text) -> a reader object (read / lines) over a string, used to feed `<` and pipes

## `M.new()`

A fake terminal. Programs write to it through the usual term API (print, write, io.write, textutils...).
obj.term is the terminal object; obj.text() returns everything written so far.

## `M.stdin(text)`

Reader over a string. read(fmt) understands "l", "L", "a", "n" (optionally with a leading "*") and byte counts.

## `M.ioFor(reader, realIo)`

A replacement `io` table for programs whose input is fed: reads come from `reader`, everything else is the real io.
