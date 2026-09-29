-- SPDX-License-Identifier: AGPL-3.0-or-later
-- init: builds the running system. Starts daemons from /etc/tsr/init.d/*.lua (sorted, each as a windowless process),
-- then the interactive session, then hands control to the kernel loop until the system stops.
local kernel = require("tsr.kernel")
local config = require("tsr.config")
local version = require("tsr.version")
local log = require("tsr.log").get("init")

local M = {}

local SHELL = "/rom/programs/shell.lua"

--- Start every daemon script in /etc/tsr/init.d.
function M.startDaemons()
  local dir = "/etc/tsr/init.d"
  if not fs.isDir(dir) then return 0 end
  local names = fs.list(dir)
  table.sort(names)
  local n = 0
  for _, name in ipairs(names) do
    if name:match("%.lua$") then
      local path = dir .. "/" .. name
      local pid, err = kernel.spawn({ name = "init.d/" .. name, path = path, window = false, daemon = true })
      if pid then n = n + 1 else log.warn("cannot start %s: %s", path, tostring(err)) end
    end
  end
  return n
end

--- The default interactive session: the stock CraftOS shell running as a Tessera process.
function M.startShellSession(parentShell)
  return kernel.spawn({
    name = "shell", session = true, focus = true,
    fn = function()
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.white)
      term.clear()
      term.setCursorPos(1, 1)
      if term.isColor() then term.setTextColor(colors.lightBlue) end
      print(version.name .. " " .. version.version)
      term.setTextColor(colors.white)
      local env = { shell = parentShell, multishell = rawget(_G, "multishell") }
      os.run(env, SHELL)
    end,
  })
end

--- opts: parentShell (the CraftOS shell API of the startup context), onReady (called right before the loop starts)
--- Returns the kernel's exit action ("craftos", "shutdown" or "reboot").
function M.run(opts)
  opts = opts or {}
  kernel.init()
  M.startDaemons()
  M.startShellSession(opts.parentShell)
  log.info("system up (profile %s)", require("tsr.profile").get())
  if opts.onReady then opts.onReady() end
  return kernel.run()
end

return M
