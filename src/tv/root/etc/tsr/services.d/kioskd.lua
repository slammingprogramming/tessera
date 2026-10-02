-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Runs the command from /etc/tsr/kiosk.cfg for ever.
return {
  description = "kiosk",
  module = "tsr.tv.kiosk",
  entry = "daemon",
  
  autostart = false,
  restart = "on-failure",
}
