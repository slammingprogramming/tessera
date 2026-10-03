# tsr.inet.stack

Package: `inet`

The IPv4 stack of one computer: interfaces, ARP, routing, forwarding, fragmentation and reassembly, ICMP, hooks for firewalls and NAT, and
the dispatch to UDP and TCP. It is driven from outside: frames come in through stack:input(iface, frame), time passes through stack:tick(),
and frames leave through the `send(frame)` function that each interface was given. That makes the stack testable without a game (see
tests/lib/inetsim.lua) and lets the same code run over wired modems, wireless modems, a Wi-Fi link or a virtual cable.

  local stack = Stack.new{ clock = os.clock, hostname = "gw" }
  local eth0 = stack:addInterface{ name = "eth0", mac = B.makeMac(os.getComputerID(), 0), send = function(frame) ... end }
  stack:setAddress("eth0", "10.0.0.2", 24)
  stack:addRoute("0.0.0.0/0", "10.0.0.1")
  stack:ping("10.0.0.1")

## `M.new(opts)`

opts: clock (function -> seconds), wait (blocking-call helper, see tsr.inet.socket), hostname, forwarding (bool), random (function(n) -> 1..n).

## `Stack:run(fn, ...)`

Run `fn` so that anything it triggers through loopback is delivered when the outermost call returns (never recursively).

## `Stack:wake()`

Called when something happened that a blocked caller may be waiting for.

## `Stack:after(delay, fn)`

Call fn after `delay` seconds (on the stack's clock). Returns an id for cancelTimer.

## `Stack:addInterface(spec)`

spec: name, mac (6 bytes), mtu (1500), kind ("ethernet" | "wifi" | "loopback" | "virtual"), send (function(frame)), parent + vlan for 802.1Q
subinterfaces. Returns the interface table.

## `Stack:addVlan(parent, vid, name)`

Add a VLAN subinterface "<parent>.<vid>" (802.1Q).

## `Stack:setAddress(name, ip, plen)`

Give an interface an address ("10.0.0.2", 24). Adds the connected route and announces the address with a gratuitous ARP.

## `Stack:joinGroup(ip)`

Receive packets sent to the multicast group `ip` (e.g. 224.0.0.9 for RIP).

## `Stack:isLocal(ip)`

Is `ip` one of our own addresses?

## `Stack:addRoute(dest, gateway, opts)`

Add a route. dest is "a.b.c.d/n" (or "default"); gateway is an address or nil (on-link). opts: iface, metric, proto, src.

## `Stack:lookup(dst, onlyIface)`

Longest-prefix match. Ties go to the lower metric, then to the older route. Routes on interfaces that are down are skipped.

## `Stack:sourceFor(route, dst)`

The source address to use when sending to `dst` via `route`.

## `Stack:addTap(fn)`

fn(direction "rx" | "tx", iface, frame). Returns a function that removes the tap.

## `Stack:transmit(iface, dstMac, ethType, payload)`

Send an Ethernet frame out of `iface` (a VLAN subinterface tags it and goes out through its parent).

## `Stack:txRaw(iface, frame)`

Send a complete frame out of an interface unchanged (bridges, switches and Wi-Fi use this; captures and counters still see it).

## `Stack:announce(iface, ip)`

Gratuitous ARP: tell the segment who owns `ip` (RFC 5227 announcement).

## `Stack:arpRequest(iface, ip, spa)`

Ask who has `ip` (used by DHCP address conflict probes too). spa 0 = a probe.

## `Stack:linkSend(iface, nexthop, bytes, broadcast)`

Send an IP packet (bytes) to the next hop `nexthop` on `iface`, resolving the Ethernet address first.

## `Stack:input(iface, frame)`

A frame arrived on `iface` (from the driver). Hooks for switches/bridges: iface.rxhook(frame) returning true consumes the frame.

## `Stack:addHook(point, name, fn, priority)`

Register a filter at a hook point: "prerouting", "input", "forward", "output", "postrouting".
fn(stack, pkt, ctx) returns nil/"accept" or "drop" (and may change pkt; set pkt.dirty = true when it did). Lower `priority` runs first.

## `Stack:ipSend(args)`

Send an IP packet from this host. args: dst, proto, payload; optional src, ttl, tos, df, id, iface (force the interface), noroute
(the destination is on-link), broadcast. Returns true or nil + reason.

## `Stack:icmpError(pkt, typ, code, rest)`

Send an ICMP error about the packet `pkt` (parsed, with .header and .payload). Follows RFC 1122 3.2.2: never about errors, fragments
other than the first, broadcasts, or packets whose source is not a single host.

## `Stack:ipInput(iface, bytes)`

An IPv4 packet (bytes) arrived on `iface`.

## `Stack:addHost(name, ip)`

Add hosts-file style names: stack:addHost("alpha", "10.0.0.2").

## `Stack:resolve(name, timeout)`

Turn a name or dotted quad into an address: hosts table, then stack.resolver(name) if set. Returns ip or nil + reason.
