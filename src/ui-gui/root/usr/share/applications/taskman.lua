-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  name = "Task Manager", order = 40, w = 40, h = 12,
  build = function(root, win, desktop) require("tsr.gui.apps.taskman").build(root, win, desktop) end,
}
