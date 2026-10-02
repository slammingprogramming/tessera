-- SPDX-License-Identifier: AGPL-3.0-or-later
-- RIP: exchanges routes with neighbouring routers (configure in /etc/tsr/inet/rip.lua).
return {
  description = "RIP routing daemon",
  module = "tsr.inet.route.daemon",
  entry = "rip",
  requires = { "inetd" },
  autostart = false,
  restart = "on-failure",
}
