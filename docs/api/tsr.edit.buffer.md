# tsr.edit.buffer

Package: `editor`

Text buffer for the editor: lines, cursor, selection, undo/redo, search. No UI in here.
Positions are (y, x): line number and character column, both 1-based; x may be #line + 1 (just after the last character).
Every change goes through replace(), which records what it removed and inserted, so undo/redo is exact.

## `B:load(text)`

Replace the whole content (no undo history).

## `B:range(y1, x1, y2, x2)`

Text between two positions.

## `B:replace(y1, x1, y2, x2, text, kind)`

Replace the text between two positions with `text`. kind groups consecutive edits of the same sort for undo ("type", "delete").
Returns the position just after the inserted text.

## `B:selectionBounds()`

Selection bounds in document order: y1, x1, y2, x2 (or nil).

## `B:deleteSelection()`

Delete the selection (if any). Returns true when something was deleted.

## `B:move(dy, dx, extend)`

Move the cursor. `extend` keeps/starts a selection.

## `B:insert(text, autoindent)`

Type text at the cursor, replacing the selection. Newlines get the indentation of the line above when autoindent is on.

## `B:indent(width, outdent)`

Indent (or outdent) the selected lines, or insert spaces at the cursor.

## `B:find(needle, opts)`

Find `needle` starting after (or before, with backwards) the cursor, wrapping around. Plain text unless `pattern`.
Returns y, x, length or nil.

## `B:findNext(needle, opts)`

Select the next match. Returns true when found.

## `B:replaceAll(needle, replacement, ignoreCase)`

Replace every occurrence (plain text). Returns how many.
