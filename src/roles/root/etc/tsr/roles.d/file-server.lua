-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "File server: shares folders with paired computers",
  packages = { "net", "netfs" },
  services = { "netd", "netfsd" },
  notes = "Share a folder with 'netfs export <name> <folder> [--rw]'. Other computers use 'netfs mount'.",
}
