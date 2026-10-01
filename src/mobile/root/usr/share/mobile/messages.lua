-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  name = "Messages", icon = "@", order = 20,
  build = function(root, phone) require("tsr.mobile.apps").messages(root, phone) end,
}
