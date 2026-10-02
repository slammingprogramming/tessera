# tsr.tv.kiosk

Package: `tv`

Kiosk mode: run one program for ever. If it ends or crashes it is started again after a short pause, and Ctrl+T does not stop it
(the program is run with `os.pullEvent` ignoring terminate). Meant for public screens where nobody should reach a shell.
  /etc/tsr/kiosk.cfg  { command = "play /media/loop.bimg --loop --monitor tv", delay = 2 }
  kiosk set <command...> | status | run        (run in the foreground; the kioskd service does it at boot)
To get out: stop the service from another computer (`svc stop kioskd`) or remove /etc/tsr/kiosk.cfg and restart.

## `M.protectedOs()`

An `os` for kiosk programs: terminate events are swallowed.

## `M.runOnce(cfg, runner)`

Run the command once. runner(line) -> status; tests replace it. Returns whatever the runner returns.

## `M.run(cfg, env)`

The restart loop. env: runner, sleep, maxRuns (tests). Returns the number of runs.
