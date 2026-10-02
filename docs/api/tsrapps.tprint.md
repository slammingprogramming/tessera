# tsrapps.tprint

Package: `print`

tprint: print text on an attached printer. Successor of the old printer.lua script (which asked for a title and one
line of text and printed a single page): this one word-wraps, paginates, numbers the pages, checks paper and ink and
can print a file.
  tprint <file> [--title T] [--copies N] [--no-numbers] [--side name]
  tprint                       asks for a title, then reads lines until you type a single "."

## `M.wrap(text, width)`

Word-wrap `text` into lines of at most `width` characters (long words are split; blank lines are kept).

## `M.paginate(lines, perPage, firstPage)`

Split lines into pages of `perPage` lines. The first page has `firstPage` lines if given (room for a title).

## `M.plan(text, width, height, opts)`

How many pages `text` needs on a printer with the given page size.

## `M.print(printer, text, opts)`

Print `text`. opts: title, copies (default 1), numbers (default true). Returns pages printed, or nil + reason
(pages printed before a failure are reported in the message).
