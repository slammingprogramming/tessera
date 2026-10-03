# tsr.inet.route.rip

Package: `inet-route`

RIP version 2 (RFC 2453): routers tell their neighbours which networks they can reach and at what cost (hops, 1..15; 16 = unreachable), and
everybody builds a routing table from what they hear. Updates every 30 s (or at once when something changes), routes that are not refreshed
time out after 180 s, split horizon with poison reverse stops two routers counting to infinity. Messages go to the multicast group 224.0.0.9, UDP 520.

Added for safety (RIP has no protection of its own): `auth = { type = "password", key = "..." }` (RFC 2453 section 5.2) or `type = "hmac"`
(HMAC-SHA256 with a sequence number against replays; this one is Tessera's own, not part of the RFC), and `neighbors = { "10.0.0.2" }` to
accept updates only from listed routers.

## `M.new(stack, cfg)`

cfg: interfaces (names; default every interface with an address), redistribute = { "connected", "static" }, defaultRoute (advertise 0.0.0.0/0),
passive = { names that listen but do not send }, auth, neighbors, update (30), timeout (180), gc (120).

## `M.decode(data)`

Returns { command, entries = { {net, plen, nexthop, metric, tag} }, auth = { type = "password"|"hmac"|nil, key / seq / mac }, wholeTable }.

## `Rip:advertised()`

Everything we know and would advertise right now: { net, plen, metric, via (interface name it was learned on), nexthop }.

## `Rip:process(msg, src, iface)`

Process one received response message from `src` on interface `iface`.

## `Rip:expire()`

Routes whose neighbour went silent become unreachable (and are announced as such), then are forgotten.

## `Rip:sendUpdate(u, onlyIface, dst)`

Send our table out of every interface (split horizon with poison reverse), or to one neighbour.

## `Rip:workers()`

Worker functions (parallel.waitForAny / sim:spawn each).

## `Rip:describe()`

Text lines for the routectl command.
