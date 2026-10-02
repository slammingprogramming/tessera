-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Hands out addresses to other computers (configure pools in /etc/tsr/inet/dhcpd.lua).
return {
  description = "DHCP server",
  module = "tsr.dhcp.daemon",
  entry = "serverMain",
  requires = { "inetd" },
  autostart = false,
  restart = "on-failure",
}
