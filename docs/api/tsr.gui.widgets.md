# tsr.gui.widgets

Package: `ui-gui`

Widget toolkit for the Tessera desktop (written from scratch for CC: Tweaked terminals).

  local W = require("tsr.gui.widgets")
  local root = W.root(term.current())
  local ok = root:add(W.button{ x = 2, y = 2, text = "OK", onClick = function() ... end })
  root:draw()
  -- in an event loop:  root:dispatch(os.pullEvent())

Coordinates of a child are relative to its parent. Widgets: label, button, checkbox, input, list, progress, panel, dialog.
Colours come from the current theme (tsr.gui.theme), never from the widgets themselves.

## `W.wrap(text, width)`

Split text into lines of at most `width` characters (words are kept whole where possible).

## `W.class(base)`

Make a subclass of `base` (default Widget).

## `Widget:origin()`

Where children's coordinates start, relative to this widget's top-left corner (panels have a border).

## `Widget:abs()`

Absolute screen position of the top-left corner.

## `Widget:hit(px, py)`

Deepest visible widget at an absolute point (last added = on top).

## `Widget:invalidate()`

Ask the root to redraw soon (the event loop draws after each event anyway).

## `Widget:focus()`

Move keyboard focus to this widget.

## `Root:render()`

Redraw everything. Uses setVisible on windows to avoid flicker.

## `Root:dispatch(name, a, b, c)`

Feed one CraftOS event to the widget tree. Returns true when the screen should be redrawn.

## `W.label(props)`

props: text, align ("left"|"center"|"right"), role (theme text role, default "windowText"), wrap (bool), w, h

## `W.button(props)`

props: text, onClick, w (default text + 2), primary (accent colour)

## `W.input(props)`

props: text, placeholder, secret (show * instead), onChange(text), onSubmit(text), w, maxLength

## `W.list(props)`

props: items (array of strings or { text = ... }), onSelect(index, item), onActivate(index, item) (Enter / double click)

## `W.progress(props)`

props: value (0..1), text (overlay, default the percentage), w

## `W.panel(props)`

props: title, border (default true), w, h. Children are positioned inside the border (1,1 = first inner cell).

## `W.dialog(parent, opts)`

Modal-style message box centred on `parent` (a root or window content). buttons = { "OK" } or { "Yes", "No" }.
onChoice(buttonText) is called and the dialog removes itself. Returns the dialog panel.
