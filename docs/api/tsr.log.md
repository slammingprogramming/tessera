# tsr.log

Package: `core`

Logging: leveled loggers, in-memory ring buffer, size-rotated file sink.
  local log = require("tsr.log").get("kernel")
  log.info("started pid %d", pid)     -- string.format applied when extra arguments are given

## `M.get(name)`

Returns a logger table with debug/info/warn/error functions.

## `M.tail(n)`

The last `n` log lines held in memory (default all).
