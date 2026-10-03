-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "MQTT message broker for sensors, switches and displays",
  packages = { "mqtt" },
  services = { "mqttd" },
  notes = "Accounts: mqttctl user add <name>. Settings: /etc/tsr/mqtt/mqtt.lua (mqttctl init).",
}
