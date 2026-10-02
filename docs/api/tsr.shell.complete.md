# tsr.shell.complete

Package: `shell`

Tab completion for tsh. Returns the suffixes that complete the last word of `line` (the contract of CraftOS' `read`).

## `M.programs(sh, prefix)`

Program names (and aliases and builtins) that start with `prefix`, as suffixes. A prefix containing "/" completes paths.
