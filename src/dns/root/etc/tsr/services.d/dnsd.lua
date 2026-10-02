-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The name server (when `dns serve on`) and the keeper of this computer's registration (when `dns register` was used).
return {
  description = "name server and name registration",
  module = "tsr.dns.server",
  entry = "daemon",
  requires = { "netd" },
  autostart = false,
  restart = "on-failure",
}
