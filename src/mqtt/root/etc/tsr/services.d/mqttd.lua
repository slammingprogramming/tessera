-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The MQTT message broker for sensors, switches and displays (settings in /etc/tsr/mqtt/mqtt.lua; manage with mqttctl).
return {
  description = "MQTT broker",
  module = "tsr.mqtt.daemon",
  entry = "main",
  requires = { "inetd" },
  autostart = false,
  restart = "on-failure",
}
