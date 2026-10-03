# tsr.inet.bgp

Package: `bgp`

A BGP-4 speaker (RFC 4271) for connecting networks that different players run into one internet: every network is an Autonomous System (AS) with a
number; neighbouring ASes exchange the prefixes they can reach, and each router picks the best path (customer routes before peer routes before
provider routes, then the shortest AS path). A session is a TCP connection to port 179 between two routers.

Peering agreements are first-class: each neighbour has a `relationship` that sets the policy in the way real networks do it (Gao-Rexford):
  customer  pays us for transit: we prefer their routes (local-pref 200) and give them everything we know
  peer      swaps traffic for free (100): we give them our own and our customers' routes, nothing else
  provider  we pay them (50): we give them our own and our customers' routes, and learn the rest of the internet from them
Beyond that: prefix filters in both directions, a limit on the number of prefixes, AS-path prepending, communities (NO_EXPORT), route origin
validation against ROAs (a signed statement of which AS may announce a prefix, "RPKI" in the real world; here a list you keep), a shared secret.

  cfg = { as = 65001, routerId = "10.0.0.1", networks = { "10.1.0.0/16" },
          peers = { { ip = "192.0.2.2", as = 65002, relationship = "peer", maxPrefixes = 100,
                      import = { allow = { { prefix = "10.2.0.0/16", le = 24 } } }, export = { prepend = 1 }, password = "secret" } } }

## `M.new(stack, cfg)`

cfg: as, routerId, networks (prefixes originated here), holdTime (90), keepalive (hold / 3), connectRetry (10), mrai (1), peers, roas, rov ("reject" | "warn" | "off").

## `Speaker:validate(net, plen, originAs)`

Route origin validation: "valid", "invalid" or "unknown" for prefix/origin AS.

## `Speaker:importRoute(peer, prefix, attrs)`

Decide about a route received from `peer`; returns the stored route or nil + reason.

## `Speaker:recompute(key)`

Pick the best route of a prefix among the local one and what the established neighbours told us.

## `Speaker:syncStack(key, best)`

Make the route known to the IP stack (the forwarding table).

## `Speaker:exportAttrs(peer, route)`

What we would tell `peer` about `route`: the attributes to send, or nil when policy says no.

## `Speaker:advertise(peer)`

Bring `peer` up to date: withdraw what is gone, announce what is new or changed.

## `Speaker:session(peer, conn, active)`

Run one session on an open connection until it ends. `conn` is a connected tcp socket.

## `Speaker:drain(peer)`

Wait (briefly) until the writer has sent everything queued for the peer, e.g. a NOTIFICATION before the connection is closed.

## `Speaker:isActive(peer)`

Does this side open the TCP connection? (Both sides trying at once makes two sessions.)

## `Speaker:workers()`

Functions to run side by side: one session loop and one writer per peer, the listener, and the route advertisement timer.

## `Speaker:clear(ip)`

Reset a session (it will reconnect).
