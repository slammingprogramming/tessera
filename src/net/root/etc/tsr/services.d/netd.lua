-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Answers discovery, ping, time, pairing and authenticated calls. Waits for a modem if none is attached yet.
return {
  description = "network daemon (discovery, pairing, remote calls)",
  module = "tsr.net.cli",
  entry = "daemon",
  autostart = true,
  restart = "on-failure",
}
