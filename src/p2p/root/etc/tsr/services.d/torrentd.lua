-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Seeds the torrents registered with `torrent seed`; runs the tracker role or shares package files when those are switched on.
return {
  description = "torrent seeding, tracker and package sharing (in-game swarm)",
  module = "tsr.p2p.cli",
  entry = "daemon",
  requires = { "netd" },
  autostart = false,
  restart = "on-failure",
}
