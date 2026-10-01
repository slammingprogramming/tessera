-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Lets the computers named in /etc/tsr/rscreen.allow watch and control this screen (nobody, until `rscreen allow <peer>`).
return {
  description = "remote screen server",
  module = "tsr.rscreen",
  entry = "daemon",
  requires = { "netd" },
  autostart = false,
  restart = "on-failure",
}
