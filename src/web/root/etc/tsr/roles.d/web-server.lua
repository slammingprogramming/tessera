-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "Web server for pages in /srv/www",
  packages = { "web" },
  services = { "httpd" },
  notes = "Put pages into /srv/www. Settings: /etc/tsr/inet/httpd.lua.",
}
