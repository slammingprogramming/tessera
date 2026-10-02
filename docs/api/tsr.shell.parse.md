# tsr.shell.parse

Package: `shell`

tsh parser: lexer + recursive-descent parser + word expansion.

Syntax (a practical Bourne-like subset):
  cmd arg 'single' "double $VAR" $(command) ${VAR} ~ * ?     words, quoting, expansion, globs
  a | b      a > file   a >> file   a < file                  pipes and redirects
  a ; b      a && b     a || b      a &                       lists, and/or, background (runs synchronously)
  if cmd; then ...; elif ...; else ...; fi
  for x in a b c; do ...; done        while cmd; do ...; done        until cmd; do ...; done
  # comment                                                    to end of line
AST node types: simple, pipeline, and, or, list, if, for, while.

## `M.lex(src)`

Tokenize. Returns array of tokens: { t = "word", segs = {...} } or { t = "op", v = "|" } or { t = "nl" }; or nil + error.
Word segments: { lit = "text", q = "bare"|"sq"|"dq" }, { var = "NAME", q = ... }, { cmd = "text", q = ... }.

## `P:parseList(stop)`

list := and_or { (";" | "&" | newline) and_or }  — stops at a keyword in `stop` (set) or end of input.

## `M.parse(src)`

Parse source text. Returns the AST (a `list` node), or nil + error + incomplete (true when more input would help,
e.g. an open `if` or quote: the REPL then asks for a continuation line).

## `M.arith(expr, ctx)`

Evaluate integer arithmetic: + - * / % and parentheses over numbers and variable names (unset names are 0).

## `M.expand(segs, ctx)`

Expand one word into a list of strings. ctx: getVar(name), subst(commandText) -> output, cwd(), find(pattern) -> list,
home. Quoting rules follow the shell: quoted text never splits or globs.

## `M.expandOne(segs, ctx)`

Expand a word to exactly one string (redirect targets, assignments): no splitting is applied to the join.
