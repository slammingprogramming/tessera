-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The anti-virus service: scans floppies when they are inserted and updates the definitions (settings: av config show).
return {
  description = "anti-virus (disk scanning, definition updates)",
  module = "tsr.av.daemon",
  entry = "main",
  autostart = false,
  restart = "on-failure",
}
