# tsr.shell.exec

Package: `shell`

tsh interpreter: runs parsed command lines. One Shell object holds the session state (variables, aliases, working
directory, history, positional parameters). Pipelines run their stages one after another and hand the captured output of
a stage to the next as its standard input; programs written for the stock CraftOS shell run unchanged.

## `M.new(opts)`

Create a shell. opts: parentShell (a CraftOS shell API to inherit path, aliases and completions from), dir, home, user.

## `Sh:resolve(p)`

Absolute-or-relative path as the stock shell resolves it (no leading slash).

## `Sh:err(msg)`

Print an error message on the real terminal even while output is being captured.

## `Sh:findProgram(name)`

Resolve a command name to a program file (no leading slash), or nil.

## `Sh:programList(includeHidden)`

Names of the programs on the path (without .lua/.tsh), sorted. Hidden entries start with a dot.

## `Sh:withIO(stdin, wantCapture, fn)`

Run fn with standard input fed from `stdin` (a string; nil keeps the current input) and, when `capture` is set, with
output recorded instead of shown. Returns fn's status and the captured text.

## `Sh:substitute(src)`

Run `src` and return what it printed.

## `Sh:execSimple(node, stdinText, wantCapture)`

Resolve a command's words, apply redirects and run it. stdinText: piped input; capture: caller wants the output as text.

## `Sh:dispatch(words)`

Run a command given as already-expanded words: alias, builtin, then program.

## `Sh:background(node)`

`cmd &`: run in a separate kernel process when Tessera's kernel is up, otherwise just run it.

## `Sh:runString(src, name)`

Parse and run source text. Returns the exit status.

## `Sh:runLine(line)`

Run a command line the way the prompt would. Returns the status.

## `Sh:runScript(src, name, args)`

Run script text with positional parameters. `exit`/`return` end only the script.
