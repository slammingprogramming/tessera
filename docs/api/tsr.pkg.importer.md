# tsr.pkg.importer

Package: `pkg`

Interactive offline import: lets a player with NO network feed Tessera its registry and package payloads by
  * dropping a bundle file onto the terminal (file_transfer event), or
  * pasting the numbered "TSR1 ..." text lines (one paste per line; order and repeats do not matter).
Used by `pkg import` and by the installer wizard.

## `M.interactive(opts)`

Block until a complete bundle has arrived (or the user presses Ctrl+T). Returns the parsed bundle table, or nil.
opts.prompt overrides the first instruction line.
