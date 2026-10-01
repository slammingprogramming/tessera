-- SPDX-License-Identifier: AGPL-3.0-or-later
-- On a turtle: lets the controllers named in /etc/tsr/fleet.allow see its status and run whitelisted jobs.
return {
  description = "turtle fleet agent",
  module = "tsr.fleet",
  entry = "daemon",
  requires = { "netd" },
  autostart = false,
  restart = "on-failure",
}
