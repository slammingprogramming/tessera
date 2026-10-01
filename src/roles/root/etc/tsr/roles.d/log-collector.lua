-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "Log collector: stores warnings and errors sent by other computers",
  packages = { "net", "ops" },
  services = { "netd", "logd" },
  notes = "Other computers run 'logship to <this computer>' and 'svc enable logshipd'. Read logs with 'logship tail <computer>'.",
}
