-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The packet filter, connection tracking and NAT.
return {
  description = "firewall and NAT",
  module = "tsr.inet.fw.daemon",
  entry = "main",
  requires = { "inetd" },
  autostart = true,
  restart = "on-failure",
}
