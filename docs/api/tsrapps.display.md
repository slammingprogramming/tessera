# tsrapps.display

Package: `display`

display: apps for attached monitors.
  monclock [side] [--scale N] [--24h] [--real] [--seconds]     a clock that fills the monitor
  monstat  [side] [--scale N] [--interval S]                    a status board for this computer
  monwrite <text...> [--side S] [--scale N] [--color name]      show a message (empty text clears the monitor)
With no side the first monitor found is used. Colours only show on advanced monitors.

## `M.find(side, env)`

The monitor named `side`, or the first one attached. Returns monitor, name  or nil + reason.

## `M.drawCentered(mon, lines, opts)`

Draw `lines` centred (both ways) on the monitor. opts.colors = array of colours per line.

## `M.formatClock(hours, opts)`

"HH:MM[:SS]" from an in-game hour (0-24 float) or a unix time.

## `M.clockFrame(mon, opts, env)`

One frame of the clock.

## `M.statusLines(env)`

Lines for the status board.
