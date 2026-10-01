-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  name = "App Store", order = 20, w = 46, h = 16,
  build = function(root, win, desktop) require("tsr.gui.apps.store").build(root, win, desktop) end,
}
