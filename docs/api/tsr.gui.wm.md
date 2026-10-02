# tsr.gui.wm

Package: `ui-gui`

Window manager / compositor for the desktop.

Every window owns an invisible CraftOS window object (win.term). Programs and widgets draw into it; the manager composes all
windows onto the screen itself, bottom to top, together with title bars. Two kinds of windows:
  widget windows   opts.build(root, win)   build widgets on `root` (a tsr.gui.widgets root); the manager feeds it events
  process windows  opts.run(win)           a function run as a kernel process whose terminal is the window; keyboard and
                                           (translated) mouse events are forwarded to it with kernel.send
Events go in through wm:event(name, ...); wm:tick() notices changes made by processes and recomposes.

## `M.new(opts)`

opts: term (screen), top (first row available to windows, default 1), bottom (last row, default screen height - 1),
kernel (default tsr.kernel)

## `WM:clamp(win)`

Keep the title bar on screen and inside the window area.

## `WM:place(win, x, y, w, h)`

Move/resize a window (content rectangle) and tell whoever is inside.

## `WM:open(opts)`

Open a window. opts: title, w, h (content size), x, y, build | run, resizable (default true), onClose, icon.
Returns the window table (id, title, x, y, w, h, term, root | pid).

## `WM:compose()`

Draw the desktop background and every visible window.

## `WM:fingerprint()`

A cheap fingerprint of everything that is on screen from the window manager.

## `WM:slowTick()`

Give windows that want periodic updates (win.onTick) a chance to refresh. Called about once a second.

## `WM:tick(force)`

Recompose when something changed. Returns true when it redrew.

## `WM:windowAt(px, py)`

The topmost visible window whose content or title bar contains the screen point. Returns win, "title" | "content".

## `WM:event(name, a, b, c)`

Handle one event. Returns true if the window manager used it.
