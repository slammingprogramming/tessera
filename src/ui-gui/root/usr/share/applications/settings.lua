-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  name = "Settings", order = 30, w = 44, h = 14,
  build = function(root, win, desktop) require("tsr.gui.apps.settings").build(root, win, desktop) end,
}
