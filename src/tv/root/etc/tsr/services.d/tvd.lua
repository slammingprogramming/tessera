-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Lets paired remotes control this TV (the tv command shows the interface).
return {
  description = "TV remote receiver",
  module = "tsr.tv.remote",
  entry = "daemon",
  requires = { "netd" },
  autostart = false,
  restart = "on-failure",
}
