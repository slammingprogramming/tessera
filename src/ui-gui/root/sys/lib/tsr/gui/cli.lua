-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The `gui` command.
--   gui                 start the desktop now (returns here when you choose "Exit to shell")
--   gui enable|disable  start the desktop automatically at boot (or not)
--   gui theme <name>    dark, light, contrast or mono
--   gui status
-- To remove the desktop completely: `pkg remove ui-gui` (the computer simply boots into the shell again).
local theme = require("tsr.gui.theme")

local M = {}

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

function M.run(args, io, config)
  io = io or defaultIO()
  config = config or require("tsr.config")
  local cmd = args[1] or "start"
  if cmd == "start" then
    local action = require("tsr.gui.desktop").start({})
    if action == "reboot" then require("tsr.sys").reboot()
    elseif action == "shutdown" then require("tsr.sys").shutdown() end
    return true
  elseif cmd == "enable" or cmd == "disable" then
    config.set("ui.default", cmd == "enable" and "gui" or "shell", "system")
    io.say(cmd == "enable" and "The desktop will start at boot." or "The computer will boot into the shell.")
    return true
  elseif cmd == "theme" then
    local name = args[2]
    local known = false
    for _, n in ipairs(theme.order) do if n == name then known = true end end
    if not known then io.err("themes: " .. table.concat(theme.order, ", ")) return false end
    config.set("ui.theme", name, "system")
    io.say("Theme set to " .. name .. (term.isColor() and "." or " (this screen only shows grey-scale: mono is used)."))
    return true
  elseif cmd == "status" then
    io.say("at boot: " .. (config.get("ui.default", "shell") == "gui" and "desktop" or "shell"))
    io.say("theme:   " .. tostring(config.get("ui.theme", "dark")))
    io.say("screen:  " .. (term.isColor() and "colour" or "grey-scale"))
    return true
  end
  io.err("usage: gui [start] | enable | disable | theme <name> | status")
  return false
end

function M.main(args) return M.run(args) end

return M
