-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "cron scheduler (/etc/tsr/cron.tab)",
  module = "tsr.cron",
  entry = "daemon",
  requires = {  },
  autostart = true,
  restart = "on-failure",
}
