# tsr.help

Package: `help`

Built-in manuals and the first-run tour.
  thelp                 menu of topics         thelp <topic>      show one (a prefix is enough)
  thelp search <word>   topics that mention it      tsr-tour       a short guided introduction
Topics are text files /usr/share/help/<order>-<id>.txt: the first line is the title, the rest is the body. Other packages can
add their own files there.

## `M.topics()`

All topics in order: { id, title, text, file }.

## `M.find(name)`

Topic by id or unambiguous prefix.

## `M.search(word)`

Topics (and the matching lines) that mention `word`, case-insensitively.

## `M.layout(text, width)`

Cut text into lines that fit `width`.

## `M.pager(title, lines, io)`

Show lines one screen at a time (Space/PageDown next, Up/Down scroll, q leaves). io.* lets tests drive it.

## `M.run(args, io, opts)`

opts: ui (tui module), pager (function(title, lines))

## `M.tour(opts)`

Walk through the tour screens. opts.ui for tests. Returns true when it was shown to the end.
