-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Keeps Wi-Fi interfaces connected to their networks.
return {
  description = "Wi-Fi client",
  module = "tsr.inet.wifi.daemon",
  entry = "stations",
  requires = { "inetd" },
  autostart = true,
  restart = "on-failure",
}
