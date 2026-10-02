-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The Ethernet switch (configure in /etc/tsr/inet/switch.lua or with swctl).
return {
  description = "Ethernet switch",
  module = "tsr.inet.switch.daemon",
  entry = "main",
  requires = { "inetd" },
  autostart = false,
  restart = "on-failure",
}
