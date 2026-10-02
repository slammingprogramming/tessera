-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The network firewall (rules in /etc/tsr/firewall.rules; `fw` to manage them). Off until you switch it on: svc enable fwd.
return {
  description = "network firewall",
  module = "tsr.fw",
  entry = "daemon",
  requires = { "netd" },
  autostart = false,
  restart = "on-failure",
}
