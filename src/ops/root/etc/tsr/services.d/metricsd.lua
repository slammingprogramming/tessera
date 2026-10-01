-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "metrics for this computer, readable by paired computers",
  module = "tsr.metrics",
  entry = "daemon",
  requires = { "netd" },
  autostart = true,
  restart = "on-failure",
}
