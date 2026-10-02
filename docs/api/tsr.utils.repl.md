# tsr.utils.repl

Package: `utils`

repl: a Lua prompt with history, tab completion, multi-line input and readable output.
  > 1 + 2            prints 3        (an expression is evaluated and shown)
  > x = 5            statements work too; variables persist
  > for i = 1, 3 do  continues on the next line until the block is complete
  > _                the last result
  :help  :load <file>  :clear  :quit
The environment has everything from the CraftOS global table, plus `tsr` and `require` (Tessera's shared loader).

## `M.show(v, depth)`

Readable text for a value.

## `M.new(opts)`

A REPL session. opts: read(history, completer) -> line | nil, write(text), env (extra globals), maxLines (tests)
