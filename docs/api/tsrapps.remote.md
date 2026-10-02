# tsrapps.remote

Package: `turtle-remote`

Wireless turtle remote control (successor of the old "Turtles/wireless" idea).

  on the turtle:               tlisten [--pair]        wait for commands (--pair sets the shared passphrase)
  on a computer / pocket:      tcontrol [--pair] [id]  drive it with the keyboard
                               tcontrol <id> <command> [argument]      one command, printed result

Security: every request carries HMAC-SHA256(passphrase, counter|command|argument) and the turtle only accepts a
counter higher than the last one it saw from that computer, so captured messages cannot be replayed. Only a fixed set
of turtle commands is understood — the remote can never run arbitrary code on the turtle. Replies are signed too.

## `R.handle(secret, state, sender, msg)`

Handle one request from `sender`. state = { last = { [sender] = counter } } (mutated). Returns reply table, stop?

## `R.rednetNet()`

The default network: rednet on the first modem found.

## `R.serve(secret, net, io, opts)`

Serve commands until a valid `stop` arrives (or net.receive raises). opts.rounds limits messages (tests).

## `R.secret(io, force)`

The passphrase: saved, or asked for (and saved) when missing or --pair is given.

## `R.listen(args, io, net)`

tlisten

## `R.control(args, io, net)`

tcontrol
