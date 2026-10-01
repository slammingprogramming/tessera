-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  name = "Settings", icon = "=", order = 90,
  build = function(root, phone) require("tsr.mobile.apps").settings(root, phone) end,
}
