# tsr.rscreen

Package: `rscreen`

Remote screen (VNC-like for terminals).
  rview <peer>            show the other computer's screen here and send it your keyboard and mouse (F12 leaves)
  rscreen allow|deny <peer> | allowed      who may watch and control THIS computer (nobody, until you allow them)
Under Tessera the focused session's window is shared; elsewhere, the computer's terminal. Only the lines that changed are
sent. Input travels encrypted. Whoever is allowed can type as you: treat `rscreen allow` like handing over the keyboard.

## `M.source()`

The window to share: the focused Tessera session, else the current terminal. Tests can replace this function.

## `M.snapshot(win)`

What is on `win` right now.

## `M.diff(peerId, snap, full)`

Changed lines since the last frame sent to `peerId` (all of them when `full` or the size changed).

## `M.serve(node)`

Register the "screen" service on `node`.

## `M.render(t, frame, state)`

Draw a frame on terminal `t` (a term or window object). `state` remembers the last full set of lines so unchanged lines stay.

## `M.fetch(node, peer, full)`

Fetch one frame. Returns the frame or nil + error.

## `M.view(node, peer, opts)`

The viewer loop. opts: term (default current), exitKey (default keys.f12), maxFrames (tests).

## `M.run(args, io, node)`

rscreen allow|deny <peer> | allowed ; rview <peer>

## `M.daemon()`

The rscreend service.
