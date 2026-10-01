-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  name = "Terminal", icon = "$", order = 50,
  build = function(root, phone) phone:pop() phone:runProgram("tsh") end,
}
