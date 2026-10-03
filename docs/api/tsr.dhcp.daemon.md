# tsr.dhcp.daemon

Package: `dhcp`

Services: dhclient (configures every interface marked `dhcp = true` in the network configuration) and dhcpd (the server).

## `M.client()`

Client service: one thread per interface; restarts the whole set when the list of DHCP interfaces changes.

## `M.relayMain()`

Relay service: /etc/tsr/inet/dhcprelay.lua = { interfaces = { "eth0" }, servers = { "10.0.0.1" } }.

## `M.serverMain()`

Server service.
