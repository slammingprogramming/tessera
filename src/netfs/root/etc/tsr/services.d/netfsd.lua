-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Offers the folders listed in /etc/tsr/netfs.exports and keeps saved mounts connected.
return {
  description = "network file sharing",
  module = "tsr.netfs",
  entry = "daemon",
  requires = { "netd" },
  autostart = true,
  restart = "on-failure",
}
