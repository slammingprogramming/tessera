# tsr.dhcp.server

Package: `dhcp`

The DHCP server (RFC 2131): hands out addresses from pools, remembers leases across restarts, honours reservations and requests for a
particular address, answers renewals, releases, declines and informs, and serves clients behind a relay agent (giaddr).

Configuration (/etc/tsr/inet/dhcpd.lua):
  return { pools = {
    { name = "lan", iface = "eth1", network = "10.2.0.0/24", range = { "10.2.0.100", "10.2.0.200" }, router = "10.2.0.1",
      dns = { "10.2.0.1" }, domain = "lan", lease = 3600, ntp = { "10.2.0.1" }, mtu = 1500,
      reservations = { ["02:54:00:01:00:05"] = "10.2.0.50" } },
  } }

## `M.new(stack, cfg)`

stack, config table. Returns a server object (call :serve() to run it, or feed it messages with :handle for tests).

## `Server:choose(pool, mac, requested)`

Pick an address for `mac`: reservation, existing lease, the one it asked for, or the first free one.

## `Server:handle(m, ifname)`

Handle one request message. Returns a reply message table (not encoded) or nil, and the pool used.

## `Server:active()`

Active leases: list of { mac, ip, expires, pool }.

## `Server:serve()`

Run the server: receive on port 67, answer on the interface the request came from. Blocks forever (or until `self.stop`).
