-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Lets the computers named in /etc/tsr/rsh.allow run commands here (nobody, until `rsh allow <peer>`).
return {
  description = "remote shell server",
  module = "tsr.rsh",
  entry = "daemon",
  requires = { "netd" },
  autostart = true,
  restart = "on-failure",
}
