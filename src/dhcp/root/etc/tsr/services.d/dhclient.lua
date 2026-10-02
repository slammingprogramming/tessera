-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Configures network interfaces by DHCP.
return {
  description = "DHCP client",
  module = "tsr.dhcp.daemon",
  entry = "client",
  requires = { "inetd" },
  autostart = true,
  restart = "on-failure",
}
