-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The name server (configure zones in /etc/tsr/inet/named.lua).
return {
  description = "DNS name server",
  module = "tsr.inet.dns.daemon",
  entry = "main",
  requires = { "inetd" },
  autostart = false,
  restart = "on-failure",
}
