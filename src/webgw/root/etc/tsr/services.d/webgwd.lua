-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Keeps the connection to the web gateway configured with `webgw setup`.
return {
  description = "web gateway connection",
  module = "tsr.webgw",
  entry = "daemon",
  requires = { "netd" },
  autostart = false,
  restart = "on-failure",
}
