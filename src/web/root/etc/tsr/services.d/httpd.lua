-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The web server (pages in /srv/www, settings in /etc/tsr/inet/httpd.lua).
return {
  description = "web server",
  module = "tsr.inet.http.daemon",
  entry = "main",
  requires = { "inetd" },
  autostart = false,
  restart = "on-failure",
}
