# tsr.net.cli

Package: `net`

The `net` command and the netd daemon entry point.
  net status | peers | lookup [service] | ping <name|id> | time <name|id>
  net pair listen            wait for another computer (shows a one-time code)
  net pair <id> <code>       pair with a computer that is listening
  net unpair <name|id> | net name <hostname>

## `M.run(args, io, node)`

Run a subcommand. `node` defaults to the shared node; tests pass their own.

## `M.daemon()`

The netd service: wait for a modem, then answer the network until stopped.
