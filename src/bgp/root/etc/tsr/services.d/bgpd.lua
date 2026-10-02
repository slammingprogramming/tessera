-- SPDX-License-Identifier: AGPL-3.0-or-later
-- BGP: connects your network (an Autonomous System) to others (configure in /etc/tsr/inet/bgp.lua).
return {
  description = "BGP routing daemon",
  module = "tsr.inet.bgp.daemon",
  entry = "main",
  requires = { "inetd" },
  autostart = false,
  restart = "on-failure",
}
