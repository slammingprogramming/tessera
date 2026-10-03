# tsr.inet.tcp

Package: `inet`

TCP (RFC 9293, the 793 successor): the connection state machine with SYN/FIN handshakes, sliding window, retransmission timer from
RFC 6298, slow start / congestion avoidance / fast retransmit and recovery in the style of RFC 5681 and NewReno (RFC 6582), zero-window
probing, out-of-order reassembly, RST handling and TIME-WAIT. Left out on purpose: window scaling, SACK, timestamps, urgent data and
delayed ACKs (every data segment is acknowledged at once, which suits a network whose round trip is measured in game ticks).

A connection is a table (a "TCB"). tsr.inet.socket wraps it in a friendlier API.

## `M.connect(stack, raddr, rport, opts)`

Open a connection (active open). opts: src (address), sport, noDelay. Returns the TCB (state SYN_SENT) or nil + reason.

## `M.listen(stack, laddr, lport, backlog)`

Listen on laddr (0 = every address):port. Returns the listening TCB.

## `M.input(stack, iface, pkt)`

A TCP segment arrived in an IP packet.

## `M.icmpError(stack, msg, q)`

ICMP said that a segment of ours did not get through.

## `M.write(tcb, data)`

Queue data for sending. Returns how many bytes were accepted (0 when the buffer is full) or nil + reason.

## `M.read(tcb, maxBytes)`

Take up to `max` bytes of received data. Returns the data, "" when none is there yet, or nil + reason once the peer has closed and
everything was read ("closed") or the connection failed.

## `M.shutdownWrite(tcb)`

No more data from us: sends FIN after the queued data.

## `M.abort(tcb)`

Reset the connection at once.

## `M.close(tcb)`

Orderly close. A listener just stops listening.

## `M.describe(tcb)`

One line about a connection (netstat).
