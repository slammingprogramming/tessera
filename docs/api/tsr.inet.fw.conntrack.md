# tsr.inet.fw.conntrack

Package: `inet-fw`

Connection tracking: remembers every flow that passes through (or to or from) this computer, in both directions, so that a stateful firewall can
tell "a reply to something we started" from "somebody knocking", and so that NAT can translate the packets of a flow consistently.
  flow  = (protocol, source, source port, destination, destination port); ICMP echo uses the identifier as the port
  state = NEW (no reply yet), ESTABLISHED (a reply was seen), RELATED (an ICMP error about a known flow), INVALID (a TCP packet that fits no flow)
Also here: rewriting a packet's addresses and ports and repairing its checksums (what NAT needs).

## `M.tuple(pkt)`

The tuple of a parsed IP packet (nil for fragments without ports and other things we cannot follow). Returns { proto, src, sport, dst, dport, flags, icmpType }.

## `M.rewrite(pkt, c)`

Rewrite addresses and ports of `pkt` in place (any of src, dst, sport, dport) and fix the checksums. Sets pkt.dirty.

## `Table:lookup(t)`

Find the flow of a tuple: returns entry, direction ("orig" | "reply") or nil.

## `Table:track(t)`

A new (unconfirmed) entry for the first packet of a flow.

## `Table:replyFree(proto, src, sport, dst, dport)`

Is a reply tuple free (for NAT port allocation)?

## `Table:update(e, t, dir, len)`

Update the entry with a packet that belongs to it. dir: "orig" | "reply".

## `Table:gc()`

Drop expired flows.

## `Table:countFrom(src)`

How many flows start at `src` (for connection limits).
