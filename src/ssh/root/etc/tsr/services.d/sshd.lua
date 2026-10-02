-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The in-game secure shell server. Nobody can log in until a public key is authorized (sshd authorize) or password login is turned on.
return {
  description = "secure shell server (in-game)",
  module = "tsr.ssh.server",
  entry = "daemon",
  requires = { "netd" },
  autostart = true,
  restart = "on-failure",
}
