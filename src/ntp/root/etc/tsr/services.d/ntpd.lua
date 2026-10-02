-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Keeps the clock synchronised (and serves time to other computers when `ntp serve on` was used).
return {
  description = "time synchronisation",
  module = "tsr.ntp",
  entry = "daemon",
  autostart = true,
  restart = "on-failure",
}
