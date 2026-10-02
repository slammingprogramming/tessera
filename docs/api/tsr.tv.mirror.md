# tsr.tv.mirror

Package: `tv`

Screen mirroring: show what a computer's terminal shows on one or more monitors as well.
  mirror <monitor>... [-- command]    run the command (default: a shell) with its output also appearing on the monitors
  mirror copy <monitor>...            copy what is on the screen right now (windows only) and leave
A "tee" terminal forwards every drawing call to all of its targets. The first target is the master: sizes, cursor and colours
queries are answered by it; the others simply draw (monitors clip what does not fit).

## `M.tee(targets)`

A terminal object that draws on every target. targets[1] is the master.

## `M.copy(source, target)`

Redraw the current contents of `source` (a window) onto `target`. Returns true or nil + reason.

## `M.cli(args, io, env)`

env: peripheral (tests), run(line) (what to execute while mirrored)
