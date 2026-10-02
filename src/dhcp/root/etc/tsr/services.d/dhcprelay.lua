-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Passes DHCP requests of clients on this router's networks to a DHCP server elsewhere (configure in /etc/tsr/inet/dhcprelay.lua).
return {
  description = "DHCP relay agent",
  module = "tsr.dhcp.daemon",
  entry = "relayMain",
  requires = { "inetd" },
  autostart = false,
  restart = "on-failure",
}
