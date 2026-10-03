-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "Anti-virus: scans floppies when inserted and updates its definitions",
  packages = { "av" },
  services = { "avd" },
  notes = "Check it works: av testfile /test.txt then av check /test.txt. Settings: av config show.",
}
