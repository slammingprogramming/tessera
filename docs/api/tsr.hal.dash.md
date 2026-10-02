# tsr.hal.dash

Package: `power-monitor`

Live dashboards for energy stores and fluid tanks, built on the HAL (so any mod's devices that have a driver show up).
  power [watch] [--monitor <name>]     every energy store: fill bar, stored/capacity, trend and time to full/empty
  tanks [watch] [--monitor <name>]     every fluid tank: fill (when the capacity is known), amount and trend
`watch` refreshes every two seconds until a key is pressed.

## `M.sample(kind, env, now)`

One row per device. kind: "power" or "tanks". now: seconds.

## `M.line(row, width)`

The text lines for a row, sized to `width`.

## `M.power(args)`

Entry points for the power and tanks commands.

## `M.render(t, kind, rows)`

Draw rows on a terminal-like object `t`.

## `M.run(kind, args, io, env)`

power | tanks   [watch] [--monitor name]
