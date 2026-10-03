# tsr.dhcp.wire

Package: `dhcp`

DHCP messages (RFC 2131) and options (RFC 2132): the BOOTP header, the magic cookie and the option list.

## `M.encode(m)`

m: op (1 request, 2 reply), xid, secs, broadcast (bool), ciaddr, yiaddr, siaddr, giaddr, chaddr (6 bytes), options = { type = 1, routers = {..}, ... }
