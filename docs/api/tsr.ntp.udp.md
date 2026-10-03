# tsr.ntp.udp

Package: `ntp`

NTP version 4 over UDP port 123 (RFC 5905 packet format), for networks that run the IP stack (package inet). Same maths as the in-game protocol:
  offset = ((T2 - T1) + (T3 - T4)) / 2        delay = (T4 - T1) - (T3 - T2)
Servers answer every computer that asks, but ask clients to slow down ("RATE", the kiss-o'-death of RFC 5905) when they send too often, and say
stratum 16 (unsynchronised) when they do not know the time themselves.

## `M.toNtp(ms)`

Milliseconds since 1970 -> 8-byte NTP timestamp (32 bits seconds, 32 bits fraction).

## `M.encode(p)`

Build a packet. p: mode (3 client, 4 server), stratum, poll, precision, rootDelay, rootDispersion (ms), refid (4 chars or number), reference, origin, receive, transmit (ms).

## `M.query(stack, host, opts)`

One exchange. opts: clock (function -> raw UTC ms), timeout (2). Returns { offset, delay, stratum, refid, host } or nil + reason.

## `M.measure(stack, host, opts)`

Several queries; the one with the least delay wins. opts: samples (4), spacing (0.3 s), plus those of query.

## `M.server(stack, opts)`

Answer queries on UDP 123 until opts.stop. opts: clock (function -> UTC ms), stratum (function), refid (function -> text or IP number), allow (list of CIDR strings; default everybody).
Returns a function to run (a worker).
