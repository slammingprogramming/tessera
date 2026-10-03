-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "Name server for your network",
  packages = { "inet-dns" },
  services = { "named" },
  notes = "Make a zone: dnsctl zone create <origin> <ns-name> <ns-ip>.",
}
