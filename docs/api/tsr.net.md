# tsr.net

Package: `net`

Tessera networking. A Node is one computer's presence on the network: it owns a transport (rednet by default), a hostname,
a database of paired peers and a table of services it offers.

  local net = require("tsr.net")
  local node = net.default()                 -- opens the modems, uses the computer's id and hostname
  node:serve("echo", function(from, method, args) return args end)
  node:run()                                 -- (daemon) answer discovery, pings, pairing and calls

  node:lookup("echo")                        -- who offers it?            -> { {id=, host=, services=} ... }
  node:ping(id)                              -- round trip in seconds     -> number | nil
  node:pairListen{ code = "..." } / node:pairConnect(id, code)
  node:call("peername", "echo", "say", {1,2})  -- authenticated call to a paired peer

Security model: pairing exchanges a random 256-bit key protected by a one-time code that is typed on both computers.
Calls carry HMAC-SHA256 over (sender, receiver, counter, payload) so they cannot be forged or replayed; with
opts.encrypt they are also encrypted. Discovery, ping and time are unauthenticated by design (they reveal only the
hostname and service names). Nothing here can protect against someone who controls a computer or its modem hardware.

## `M.rednetTransport()`

The default transport: rednet with every attached modem opened.

## `M.defaultTransport()`

The transport nodes use unless told otherwise: rednet, or the IP network (package inet) when the setting net.transport is "ip" and the stack is running.

## `M.node(opts)`

Create a node. opts: id, hostname, transport, peersPath (default /etc/tsr/net/peers.db).

## `Node:tap(fn)`

Taps see every message that goes through the node (this is what `netmon` uses): fn(direction, node, peerId, msg, dropped) with
direction "out" (sent), "bcast" (broadcast), "in" (accepted) or "drop" (refused by the firewall). A tap must not block or fail the node.
Returns a function that removes the tap.

## `Node:send(id, msg)`

Who we talked to lately (clock seconds): replies from them are expected, so a firewall lets them through.

## `Node:receive(timeout)`

Next message for this node. A firewall (tsr.fw) may be installed as `node.firewall = function(node, from, msg) -> boolean`: messages it
refuses are dropped here, for everybody who reads from the node (the daemon, `ssh`, `torrent`...).

## `Node:await(from, want, timeout)`

Wait for a message from `from` (nil = anyone) accepted by `want(msg)`; returns the message or nil on timeout.

## `Node:peer(idOrName)`

Peer record by id or name, or nil. { id, name, key, added }

## `Node:lookup(service, timeout, host)`

Computers (answering within `timeout` seconds) that offer `service`, or that are called `host`. Returns a list of
{ id, host, services }. With neither argument: everybody who answers.

## `Node:resolve(target, timeout)`

Turn a peer name, hostname or number into a computer id.

## `Node:ping(target, timeout)`

Round-trip time in seconds, or nil.

## `Node:time(target, timeout)`

Ask another computer for its clocks. Returns { utc, ingame, rtt, offset } where offset = theirs - ours (ms, utc clock).

## `Node:pairListen(opts)`

Wait for another computer to pair using a one-time code. opts: code (default: a fresh one), timeout (seconds, default 120),
onCode(code) called as soon as the code is known (to display it), attempts (wrong codes tolerated, default 3).
Returns the peer ({ id, name }) or nil + reason.

## `Node:onPair1(from, msg)`

First message of pairing (we are the listener).

## `Node:onPair3(from, msg)`

Last message of pairing (we are the listener): the other side confirms it got the key.

## `Node:pairConnect(id, code, timeout)`

Pair with the computer `id` that is listening with `code`. Returns the peer ({ id, name }) or nil + reason.

## `Node:serve(name, handler, opts)`

Offer a service. handler(from, method, args) returns results; errors become error replies. opts.allow(peer) -> bool restricts
which paired peers may call it (default: all paired peers). opts.async runs each call in its own process when the kernel is up.

## `Node:call(target, service, method, args, opts)`

Call `service.method(args)` on a paired computer. opts: timeout (seconds), encrypt (bool). Returns the result, or nil + error.

## `Node:run()`

Answer everything addressed to this node. Never returns. Handlers run inline, so a slow service delays others: services
that take long should spawn their own process.
