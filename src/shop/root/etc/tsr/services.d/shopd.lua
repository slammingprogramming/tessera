-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Runs the shop configured with the `shop` command (stops with an error until it is set up).
return {
  description = "vending shop",
  module = "tsr.shop",
  entry = "daemon",
  autostart = false,
  restart = "on-failure",
}
