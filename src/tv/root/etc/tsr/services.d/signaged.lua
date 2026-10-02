-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Plays the slides configured with the signage command.
return {
  description = "digital signage slideshow",
  module = "tsr.tv.signage",
  entry = "daemon",
  
  autostart = false,
  restart = "on-failure",
}
