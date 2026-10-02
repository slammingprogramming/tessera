# tsr.tv.remote

Package: `tv`

TV remote control over the network.
  On the TV computer:   the tvd service offers the "tv" service to paired computers
  On a pocket computer: tvremote <tv name>      arrows, Enter = OK, Backspace = Back, Home; or tap the buttons
Pair first (`net pair`). Each button press is one signed message; the TV turns it into the event  tv_key(name).

## `M.serve(node)`

Register the "tv" service on `node`.

## `M.press(node, tv, key)`

Send one button press. Returns true, or nil + reason.

## `M.ui(node, tv, opts)`

The remote's screen. opts: term, pull (event source for tests), maxEvents. Returns when the user quits (Q) or after maxEvents.

## `M.daemon()`

The tvd service (on the TV).
