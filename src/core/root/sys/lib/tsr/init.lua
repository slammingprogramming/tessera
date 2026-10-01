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

--- Run tsh (package `shell`) when it is installed and not switched off with `shell.default = "craftos"`. Returns true when the
--- user left it normally; false means "use the stock shell instead" (not installed, or it failed).
local function runTsh(parentShell, user)
  if config.get("shell.default", "tsh") ~= "tsh" or not fs.exists("/sys/lib/tsr/shell/repl.lua") then return false end
  local ok, err = pcall(function()
    require("tsr.shell.repl").session({ parentShell = parentShell, home = user and user.home, user = user and user.name })
  end)
  if ok then return true end
  log.error("tsh stopped with an error, falling back to the CraftOS shell: %s", tostring(err))
  return false
end

--- Ask who is using the computer when the `auth` package is installed and has users. Returns the user, or nil for an open system.
local function login()
  if config.get("auth.login", true) == false or not fs.exists("/sys/lib/tsr/login.lua") then return nil end
  local ok, res = pcall(function()
    if not require("tsr.auth").hasUsers() then return nil end
    return require("tsr.login").run({})
  end)
  if ok then return res end
  log.error("login failed to start, continuing without it: %s", tostring(res))
  return nil
end

--- Run the desktop when the `ui-gui` package is installed and switched on (`gui enable`, or Settings). Returns the way it was left:
--- "shell", "logout", "reboot", "shutdown"; or nil when there is no desktop to run (not installed, off, or it failed).
local function runGui()
  if config.get("ui.default", "shell") ~= "gui" or not fs.exists("/sys/lib/tsr/gui/desktop.lua") then return nil end
  local ok, action = pcall(function() return require("tsr.gui.desktop").start({}) end)
  if ok then return action or "shell" end
  log.error("the desktop stopped with an error, using the shell instead: %s", tostring(action))
  return nil
end

--- The default interactive session: tsh when installed, otherwise the stock CraftOS shell, as a Tessera process.
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
      while true do
        local user = login()
        local again = true
        while again do
          again = false
          local action = runGui()
          if action == "reboot" or action == "shutdown" then
            local sys = require("tsr.sys")
            if action == "reboot" then sys.reboot() else sys.shutdown() end
            return
          elseif action ~= "logout" then
            if not runTsh(parentShell, user) then
              local env = { shell = parentShell, multishell = rawget(_G, "multishell") }
              os.run(env, SHELL)
            end
            again = action == "shell"       -- came from the desktop's "Exit to shell": back to the desktop afterwards
            term.setBackgroundColor(colors.black)
            term.clear()
            term.setCursorPos(1, 1)
          end
        end
        if not user then return end          -- an open system: leaving the shell ends the session
        require("tsr.auth").endSession()     -- logged out: back to the login prompt
        term.setBackgroundColor(colors.black)
        term.clear()
      end
    end,
  })
end

--- opts: parentShell (the CraftOS shell API of the startup context), onReady (called right before the loop starts)
--- Returns the kernel's exit action ("craftos", "shutdown" or "reboot").
function M.run(opts)
  opts = opts or {}
  kernel.init()
  if config.get("auth.guard", true) and fs.exists("/sys/lib/tsr/auth.lua") then
    local ok, err = pcall(function() require("tsr.auth").guard.install() end)
    if not ok then log.error("file guard not installed: %s", tostring(err)) end
  end
  M.startDaemons()
  M.startShellSession(opts.parentShell)
  log.info("system up (profile %s)", require("tsr.profile").get())
  if opts.onReady then opts.onReady() end
  return kernel.run()
end

return M
