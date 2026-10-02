# tsr.edit.lua

Package: `editor`

Lua syntax colouring for the editor. highlight(lines) returns, for each line, a string with one colour letter per character:
  k keyword, s string, c comment, n number, f well-known function/library, o other.

## `M.highlight(lines)`

Colour letters for every line of `lines`.
