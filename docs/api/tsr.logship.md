# tsr.logship

Package: `ops`

Central logging.
  Collector (one computer):  logd service -> /var/log/remote/<computer name>.log (rotated at 32 KB)
  Shippers (the others):     logship service sends warnings and errors to the collector named in config `log.remote`
  logship tail <name> [n]    show the last lines collected from a computer

## `M.serve(node)`

Register the "log" service on `node`.

## `M.hook(level)`

Start collecting log lines at or above `level` (default warn) for shipping.

## `M.flush(node, peer)`

Send queued lines to `peer` through `node`. Returns the number sent, or nil + error (the lines stay queued).

## `M.shipDaemon()`

The logship service: keep sending to the collector named in config `log.remote`.

## `M.collectDaemon()`

The logd service.

## `M.run(args, io)`

logship tail <computer> [n] | to <collector> | status
