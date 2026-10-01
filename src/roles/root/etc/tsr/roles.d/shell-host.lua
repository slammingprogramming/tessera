-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "Remote shell host: lets chosen computers run commands here",
  packages = { "net", "rsh", "shell" },
  services = { "netd", "rshd" },
  notes = "Nobody may log in until you run 'rsh allow <computer name>' (after pairing with 'net pair').",
}
