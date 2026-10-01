-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "Remote screen: lets chosen computers watch and control this screen",
  packages = { "net", "rscreen" },
  services = { "netd", "rscreend" },
  notes = "Allow a paired computer with 'rscreen allow <name>'; it then runs 'rview <this computer>'.",
}
