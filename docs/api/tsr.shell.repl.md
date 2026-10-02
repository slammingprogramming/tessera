# tsr.shell.repl

Package: `shell`

tsh interactive loop: prompt, history, completion, multi-line input, startup files.

## `M.prompt(sh, which)`

Expand the prompt string: \w working directory, \u user, \h host, \$ "$", \n newline.

## `M.run(sh, opts)`

Run the interactive loop on `sh` until it exits. opts: read (function(history, completeFn) -> line | nil, for tests),
noRc (skip profile and rc files).

## `M.session(opts)`

The default interactive session (used by the kernel). opts: parentShell.
