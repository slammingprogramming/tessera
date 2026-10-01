-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Terminal: tsh (or the CraftOS shell when tsh is not installed) in a window. Runs as a process whose terminal is the window.
local M = {}

function M.run(win)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  local okRepl, repl = pcall(require, "tsr.shell.repl")
  if okRepl then
    local ok, err = pcall(repl.session, { parentShell = rawget(_G, "shell") })
    if ok then return end
    printError("tsh stopped: " .. tostring(err))
  end
  os.run({ shell = rawget(_G, "shell"), multishell = rawget(_G, "multishell") }, "/rom/programs/shell.lua")
end

return M
