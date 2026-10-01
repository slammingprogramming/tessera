-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  name = "Terminal", order = 5, w = 46, h = 14,
  run = function(win, desktop) require("tsr.gui.apps.terminal").run(win) end,
}
