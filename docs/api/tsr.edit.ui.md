# tsr.edit.ui

Package: `editor`

ted: the editor's screen, keyboard and mouse handling on top of tsr.edit.buffer.
  Ctrl+S save   Ctrl+Q quit   Ctrl+F find   F3 / Shift+F3 next/previous   Ctrl+H replace all   Ctrl+L go to line
  Ctrl+Z / Ctrl+Y undo / redo   Ctrl+A select all   Ctrl+C / X / V copy / cut / paste   Ctrl+K delete line
  Tab / Shift+Tab indent / outdent   Shift+arrows select   mouse: click, drag, wheel

## `M.new(opts)`

opts: path, term, text (instead of reading path), readFile/writeFile (tests), tabWidth

## `UI:event(name, a, b2, c)`

Handle one event. Returns true when the screen should be redrawn.

## `UI:run()`

Run the editor on the terminal until the user quits.
