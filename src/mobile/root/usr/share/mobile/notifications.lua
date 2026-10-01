-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  name = "Alerts", icon = "!", order = 10,
  build = function(root, phone) require("tsr.mobile.apps").notifications(root, phone) end,
}
