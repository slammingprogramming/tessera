# tsr.ui.tui

Package: `ui-tui`

Text UI toolkit. Keyboard-first (works on basic computers, turtles and pocket computers), with mouse support where
the terminal has it. Colours degrade to black/white/gray on basic screens. All screens are drawn on the current
terminal, so they also work inside windows (tests redirect term to a window and inspect it).
  tui.menu(title, items, opts)       -> index | nil (Backspace)
  tui.checklist(title, items, opts)  -> { [id] = bool } | nil (Backspace)
  tui.confirm(title, lines, opts)    -> boolean
  tui.message(title, lines)          tui.input(title, prompt, default)   tui.bar(y, fraction)

## `M.wrap(text, width)`

Word-wrap `text` to `width` columns. Returns an array of lines.

## `M.frame(title)`

Clear the screen and draw the title bar. Returns width, height.

## `M.bar(y, fraction, label)`

Draw a progress bar on row y. fraction 0..1.

## `M.menu(title, items, opts)`

Single choice. items: { {label, desc?, disabled?, tag?, tier?} }. Returns the chosen index or nil (Backspace).

## `M.checklist(title, items, opts)`

Multiple choice. items: { {id, label, desc?, disabled?, tag?, tier?} }; opts.checked = { [id] = true }.
Returns { [id] = bool } or nil (Backspace).

## `M.message(title, lines)`

Show text and wait for a key.

## `M.confirm(title, lines, opts)`

Yes/No question. opts.default (bool). Returns true/false.

## `M.input(title, prompt, default)`

Ask for a line of text. Returns the string (possibly empty).

## `M.status(text)`

One-line status message at the bottom of a frame (used while work is in progress).
