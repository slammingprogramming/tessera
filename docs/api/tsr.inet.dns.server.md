# tsr.inet.dns.server

Package: `inet-dns`

The name server: authoritative for the zones it is given (primary from files, secondary by zone transfer), recursive for the networks you allow
(iterating from the root hints you configure, or forwarding), with a cache. UDP and TCP on port 53; answers longer than 512 bytes are truncated
on UDP so clients retry over TCP; zone transfers (AXFR) go to the servers you list.

Configuration /etc/tsr/inet/named.lua:
  return {
    zones = {
      { origin = "example.lan", file = "/etc/tsr/inet/zones/example.lan.zone", allowTransfer = { "10.0.0.3" }, notify = { "10.0.0.3" } },
      { origin = "other.lan", type = "secondary", masters = { "10.0.0.9" } },
    },
    recursion = true,                       -- answer recursive queries (for the networks below)
    allowRecursion = { "10.0.0.0/8" },      -- default: the networks this server is connected to
    roots = { "10.0.0.1" },                 -- root hints: where to start iterating
    forwarders = {},                        -- or: ask these resolvers instead of iterating ("upstream" = the DNS servers learned by DHCP)
  }

## `Server:loadZones()`

Load the zones of the configuration. Returns problems (strings).

## `Server:zoneFor(name)`

The zone that is authoritative for `name`: the one with the longest matching origin.

## `Server:answer(q, src, tcp)`

Answer a decoded query from `src`. Returns a reply table (to be encoded) or nil to stay silent.

## `Server:handle(data, src, tcp)`

Raw message in, raw message out (nil = no answer). maxSize cuts UDP answers.

## `Server:pullZone(origin)`

Fetch a zone from a master (AXFR) into a secondary zone object. Returns true or nil + reason.

## `M.axfr(stack, master, origin)`

AXFR client: returns a Zone or nil + reason.

## `Server:workers(n)`

Worker functions to run side by side (parallel.waitForAny, or sim:spawn each in tests): UDP receivers, TCP acceptors, secondary refresh.
