# tsr.sys

Package: `core`

The application-facing system API (also exposed as the global `tsr` once booted). Apps should depend on this
module rather than on kernel internals.

## `S.spawn(spec)`

Start a process (see kernel.spawn for the spec fields).

## `S.exec(path, ...)`

Run a Lua program as a child process and wait for it. Returns ok, err.

## `S.exit()`

Leave Tessera and return to the plain CraftOS shell.

## `S.sourceInfo()`

AGPL-3.0 section 13: where the corresponding source of this system can be obtained.
