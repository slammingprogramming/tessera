-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "Modbus/TCP slave: exposes redstone and machines to a control room",
  packages = { "modbus", "hal" },
  services = { "modbusd" },
  notes = "Write the address map first: modbusctl init, edit /etc/tsr/modbus.lua (set the allow list!).",
}
