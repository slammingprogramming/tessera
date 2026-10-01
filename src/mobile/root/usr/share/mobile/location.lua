-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  name = "Location", icon = "+", order = 30,
  build = function(root, phone) require("tsr.mobile.apps").location(root, phone) end,
}
