# tsr.inet.http.www

Package: `web`

A text web browser for the in-game web (and for local HTML files).
  www [url]          Up/Down/PgUp/PgDn scroll, Tab / Shift+Tab pick a link, Enter follows it (or click it), Backspace goes back, G types an address,
                     R reloads, S saves the page, Q quits

## `M.load(url, width, opts)`

Fetch and lay out a page. Returns a page table { url, status, title, lines, links, type, body } or nil + reason.

## `M.draw(t, page, state)`

Draw the page into `t` (a term object): title bar, text, status line.

## `M.linkAt(page, state, row, col)`

The link on screen row `row` and column `col`, if any.

## `M.board(url, opts)`

A display board for information pages: shows a page on a monitor (or this screen), loads it again every `interval` seconds and turns the pages of a long one
every `flip` seconds. Runs until Ctrl+T. opts: term, stack, interval (30), flip (8), sleep, clock, maxRounds (tests). Returns the number of rounds it ran.

## `M.browse(url, opts)`

opts: term (default the current terminal), stack, events (function() -> event table, default os.pullEvent), prompt (function(text) -> string, default read()).
