-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Serves cached packages to paired computers. Off by default: enable it on the computer that should act as the mirror
-- (`svc enable pkgmirrord`).
return {
  description = "package mirror server",
  module = "tsr.pkgmirror",
  entry = "daemon",
  requires = { "netd" },
  autostart = false,
  restart = "on-failure",
}
