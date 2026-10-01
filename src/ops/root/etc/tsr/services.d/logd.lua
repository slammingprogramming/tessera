-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "collects logs sent by other computers",
  module = "tsr.logship",
  entry = "collectDaemon",
  requires = { "netd" },
  autostart = false,
  restart = "on-failure",
}
