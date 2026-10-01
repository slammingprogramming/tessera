-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "Monitoring: metrics other computers can read, plus cron",
  packages = { "net", "ops" },
  services = { "netd", "metricsd", "crond" },
  notes = "Read metrics with 'metrics <computer>'. Schedule jobs with 'crontab add every 10m <command>'.",
}
