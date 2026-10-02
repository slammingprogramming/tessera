# tsrapps.cli

Package: `app-kit`

Shared helpers for command-line apps: option parsing, prompts and coloured output. Every function that talks to the
user goes through an `io` table, so apps can be driven by tests without a keyboard.

## `C.parse(args, spec)`

Parse `args` according to `spec`: { name = "bool" | "number" | "string", ... }, plus spec._alias = { y = "yes" }.
Accepts --name, --name value and --name=value. Returns positional (array), options (table), or nil + error.

## `C.io()`

The default io table: say/warn/err print (coloured), prompt reads a line, ask does yes/no.

## `C.count(value, default)`

Number from a positional/prompt value with a default; nil when it is not a positive integer.

## `C.columns(rows, gap)`

Plain-text table: rows = array of arrays of strings. Returns lines.

## `C.require(name)`

Load an app module through the shared loader when Tessera is running, otherwise via a private loader.
