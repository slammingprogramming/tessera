-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "Mail server: SMTP and POP3 for your domains",
  packages = { "mail", "mail-spam", "av" },
  services = { "maild", "avd" },
  notes = "First: mailctl init, mailctl domain add <domain>, mailctl user add <name>. Publish the DNS records shown by: mailctl dns.",
}
