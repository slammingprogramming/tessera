# tsr.tv.shell

Package: `tv`

The TV interface: a home screen of big tiles on a monitor, driven by a remote (arrow keys, OK, Back) or by touching the monitor.
Remote keys arrive as the event  tv_key(name)  with names up, down, left, right, ok, back, home (see tsr.tv.remote), or as
ordinary key events. Apps: Media (play files from /media), Signage (the configured slideshow), Dashboard (power and tanks), Settings.

## `M.new(opts)`

opts: monitor (peripheral name; default the computer's own screen), term (tests), scale (text scale, default 1),
peripheral (tests), mediaDir

## `TV:play(file)`

Play a library entry full-screen on the TV; any key, touch or remote button stops it.

## `TV:moveFocus(dx, dy)`

Move focus to the nearest focusable widget in a direction (for tile grids).

## `TV:event(ev, a, b, c)`

Handle one event. Returns true when it did something.

## `M.start(opts)`

Start the TV interface. opts: monitor, scale. Returns "shell" | "reboot" | "shutdown".
