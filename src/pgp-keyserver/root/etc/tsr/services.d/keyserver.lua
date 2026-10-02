-- SPDX-License-Identifier: AGPL-3.0-or-later
-- An in-game key server for the computers paired with this one (public keys only). Not started by default.
return {
  description = "in-game PGP-style key server",
  module = "tsr.pgp.keyserver",
  entry = "daemon",
  requires = { "netd" },
  autostart = false,
  restart = "on-failure",
}
