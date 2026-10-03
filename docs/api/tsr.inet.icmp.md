# tsr.inet.icmp

Package: `inet`

ICMP (RFC 792): echo (ping), destination unreachable, time exceeded. Errors that name a TCP or UDP packet are passed on to the transport
layer (stack.icmpHandlers[proto]). `probe` sends one echo with a chosen TTL, which is all ping and traceroute need.

## `M.probe(stack, dst, opts)`

Send one echo request and wait for the answer. opts: ttl, size (payload bytes, 32), timeout (2), df, src, id, seq.
Returns { ok = true, from, rtt, ttl, bytes } | { ok = false, reason = "timeout" | "ttl exceeded" | "unreachable", from } | nil + error.
