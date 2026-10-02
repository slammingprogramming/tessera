# tsr.util

Package: `core`

Small shared helpers. Only add things that at least two modules need.

## `M.merge(dst, src)`

Recursively merge `src` into `dst` (tables merge, everything else overwrites). Returns dst.

## `M.freeSpace(path)`

Free bytes on the root filesystem as a number (mounts that report "unlimited" give math.huge).

## `M.isEscape(code)`

Is this key code the Escape key? CC's `keys` table has no entry for it in older versions (the key code is 1 there, 256 in
versions that use GLFW codes), so compare against the raw codes as well as a possible `keys.escape`.

## `M.timestamp()`

Timestamp used in logs, e.g. "2026-09-29 12:34:56".
