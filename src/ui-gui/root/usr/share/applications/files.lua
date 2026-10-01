-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  name = "Files", order = 10, w = 46, h = 15,
  build = function(root, win, desktop) require("tsr.gui.apps.files").build(root, win, desktop) end,
}
