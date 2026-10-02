# tsr.rsh

Package: `rsh`

Remote shell.
  rsh <peer>                 interactive session on a paired computer
  rsh <peer> <command...>    run one command there and print its output (also: rexec)
  rsh allow <peer> | deny <peer> | allowed      choose who may run commands HERE (nobody, until you allow them)

A remote command is as powerful as typing at the keyboard, so access is limited to paired computers you named. Commands run
in a tsh session that is kept per remote computer (working directory and variables persist between commands) inside their
own process with a time limit; programs that wait for the keyboard are stopped when the limit passes.

## `M.reset()`

Forget every remote session (tests; also useful after the shell package is upgraded).

## `M.execute(sh, line, timeout)`

Run `line` in `sh` capturing everything it prints. Returns status, output, timedOut.

## `M.serve(node)`

Register the "shell" service on `node`.

## `M.exec(node, peer, line, opts)`

Run a command on a peer. Returns the reply table ({status, output, cwd,...}) or nil + error.

## `M.daemon()`

The rshd service: register the shell service and idle.
