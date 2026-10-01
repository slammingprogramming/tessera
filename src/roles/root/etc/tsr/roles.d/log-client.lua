-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "Log client: sends warnings and errors to a log collector",
  packages = { "net", "ops" },
  services = { "netd", "logshipd" },
  notes = "Name the collector first: 'logship to <collector name>' (it must be paired).",
}
