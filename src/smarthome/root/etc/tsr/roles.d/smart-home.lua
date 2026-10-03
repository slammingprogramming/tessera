-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "Smart-home hub with scenes, schedule and MQTT bridge",
  packages = { "smarthome", "mqtt", "hal" },
  services = { "mqttd", "homed" },
  notes = "Name your devices: home init, edit /etc/tsr/home.lua.",
}
