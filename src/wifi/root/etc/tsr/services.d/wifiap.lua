-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A Wi-Fi access point (configure in /etc/tsr/inet/wifi-ap.lua).
return {
  description = "Wi-Fi access point",
  module = "tsr.inet.wifi.daemon",
  entry = "accessPoints",
  requires = { "inetd" },
  autostart = false,
  restart = "on-failure",
}
