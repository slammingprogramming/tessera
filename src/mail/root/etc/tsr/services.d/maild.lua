-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The mail server: SMTP, POP3, the delivery queue, anti-spam and anti-virus (settings in /etc/tsr/mail/mail.lua; manage with mailctl).
return {
  description = "mail server (SMTP, POP3)",
  module = "tsr.mail.daemon",
  entry = "main",
  requires = { "inetd" },
  autostart = false,
  restart = "on-failure",
}
