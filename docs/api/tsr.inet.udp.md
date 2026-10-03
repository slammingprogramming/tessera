# tsr.inet.udp

Package: `inet`

UDP (RFC 768): datagram sockets. A socket is a table; use tsr.inet.socket for the friendly API.

## `M.bind(s, addr, port)`

Bind to an address (0 = any) and port (0 or nil = pick one).

## `M.sendto(s, data, dst, dport, opts)`

Send a datagram. opts: iface (send out of this interface), src (source address), ttl, tos.

## `M.icmpError(stack, msg, q)`

ICMP unreachable about a datagram we sent: remember it for the connected socket.

## `M.receive(s, timeout)`

Take the next datagram, waiting up to `timeout` seconds (nil = forever, 0 = do not wait). Returns the datagram table or nil + reason.
