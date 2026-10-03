# tsr.inet.switch.stp

Package: `inet-switch`

The Spanning Tree Protocol (IEEE 802.1D): bridges elect a root, every other bridge picks the cheapest path to it (its root port), each segment
picks one designated bridge, and every other port is blocked, so that redundant cables never become a loop. Frames: configuration BPDUs to the
multicast address 01:80:C2:00:00:00. Ports pass through listening and learning before they forward, so a loop cannot form while the tree settles.

Bridge ID  = priority (2 bytes) + MAC (6 bytes), compared as a string: the lowest wins.
Port  ID   = priority (1 byte, 128) + port number (1 byte).
Priority vector of a BPDU = (root ID, cost to root, sender bridge ID, sender port ID): the smaller vector is better.

## `M.new(sw, cfg)`

sw: the switch (needs sw.stack, sw.ports (name -> port), sw.mac, sw:sendRaw(port, dst, ethType, payload), sw:topologyChange()).
cfg: priority (32768), hello (2), maxAge (20), forwardDelay (15), cost (19 per port).

## `Stp:advance(port)`

Move a port toward forwarding: listening -> learning -> forwarding, each after forwardDelay.

## `Stp:recompute()`

Work out root, root port and the role of every port from the stored BPDUs.

## `Stp:receive(port, payload)`

A BPDU arrived on `port`.

## `Stp:topologyDetected()`

Called every hello interval and whenever the topology may have changed.
This bridge saw a port enter or leave forwarding: tell the root (TCN) or, as the root, announce it to everybody (TC flag in the BPDUs).

## `Stp:topologyAnnounced()`

The root announced a topology change (TC flag): forget learned addresses and shorten aging for a while.

## `Stp:start()`

Start the periodic hello (and aging) timer.

## `Stp:describe()`

Text for `swctl show stp`.
