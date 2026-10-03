-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Modbus/TCP slave: exposes redstone ports and machines to a control room (settings: /etc/tsr/modbus.lua).
return {
  description = "Modbus/TCP slave",
  module = "tsr.modbus.daemon",
  entry = "main",
  requires = { "inetd" },
  autostart = false,
  restart = "on-failure",
}
