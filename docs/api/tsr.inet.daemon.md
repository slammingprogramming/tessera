# tsr.inet.daemon

Package: `inet`

The inetd service: creates the network stack of this computer, applies /etc/tsr/inet/network.lua, and then keeps it alive: modem messages go
in, timers tick, and modems that are plugged in or removed are picked up. Other services (dhcpd, dnsd, httpd, ...) use the stack through
tsr.inet.socket in their own processes.

## `M.create(cfg)`

Build the stack from the configuration. Separate from main() so that it can be tested.

## `M.rescan(stack, cfg)`

Hotplug: attach interfaces for modems that appeared since the last look (only in automatic mode) and drop those that vanished.
