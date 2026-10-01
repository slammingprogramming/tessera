-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  name = "Remote", icon = ">", order = 40,
  build = function(root, phone) require("tsr.mobile.apps").remote(root, phone) end,
}
