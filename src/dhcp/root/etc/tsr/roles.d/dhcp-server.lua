-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "DHCP server: hands out addresses",
  packages = { "dhcp" },
  services = { "dhcpd" },
  notes = "Describe the pools in /etc/tsr/inet/dhcpd.lua, then svc restart dhcpd.",
}
