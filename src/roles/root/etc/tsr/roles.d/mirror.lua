-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "Package mirror: caches packages and serves them to paired computers without internet",
  packages = { "net", "pkg-mirror" },
  services = { "netd", "pkgmirrord" },
  notes = "Pair the computers that should use it (net pair), then run 'pkgmirror prefetch' while this computer has internet. On clients: 'pkgmirror add <name>'.",
}
