-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Watches Mekanism fission reactors and SCRAMs them on unsafe readings (see /sys/lib/tsr/scada.lua). Does nothing when no
-- reactor is attached.
return {
  description = "reactor safety supervision",
  module = "tsr.scada",
  entry = "daemon",
  autostart = true,
  restart = "always",
}
