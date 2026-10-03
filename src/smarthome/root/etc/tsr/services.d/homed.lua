-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The smart-home service: scene schedule and the MQTT bridge (settings: /etc/tsr/home.lua).
return {
  description = "smart home hub (schedule, MQTT bridge)",
  module = "tsr.home.daemon",
  entry = "main",
  autostart = false,
  restart = "on-failure",
}
