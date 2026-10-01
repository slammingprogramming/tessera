-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Evaluates the rules in /etc/tsr/rules.d once a second and runs their actions.
return {
  description = "automation rules engine",
  module = "tsr.rules",
  entry = "daemon",
  autostart = true,
  restart = "on-failure",
}
