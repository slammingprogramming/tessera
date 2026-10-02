# tsr.metrics

Package: `ops`

Metrics: a snapshot of how this computer is doing, readable locally (`metrics`) and by paired computers (`metrics <peer>`).
Everything is a number or short string so it can be graphed or shown on a monitor by other tools.

## `M.hookLog()`

Count warnings/errors written to the system log from now on (the `metricsd` service calls this).

## `M.collect(extra)`

Collect the gauges. `extra` is an optional table merged in (for tests and plugins).

## `M.serve(node)`

Register the "metrics" service on `node` (method "get" returns the snapshot).

## `M.run(args, io, node)`

metrics [peer]

## `M.daemon()`

The metricsd service.
