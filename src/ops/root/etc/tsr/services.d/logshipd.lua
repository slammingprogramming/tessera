-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "sends warnings and errors to the collector in config log.remote",
  module = "tsr.logship",
  entry = "shipDaemon",
  requires = { "netd" },
  autostart = false,
  restart = "on-failure",
}
