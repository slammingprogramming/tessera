-- SPDX-License-Identifier: AGPL-3.0-or-later
-- tsr-setup: the Tessera setup wizard (run it any time to add or remove features).
--   tsr-setup                interactive
--   tsr-setup --auto         unattended: accept every recommendation and default, do not reboot
--   tsr-setup --source <dir> use a mirror directory (disk, mounted folder) as the package source
--   tsr-setup --reboot       with --auto: reboot when finished
--   tsr-setup --usecase <id> choose what the computer is for without asking (router-home, router-business, switch, access-point, firewall, infrastructure,
--                            mail-server, web-server, package-mirror, iot-node, smart-home, industrial, kiosk, workstation, server)
--   tsr-setup usecases       list the use cases and say which ones this computer's hardware allows
local req = (rawget(_G, "tsr") and tsr.require) or require
local wizard = req("tsr.setup.wizard")

local args = { ... }
local opts = { auto = false }
local sourceDir, reboot
do
  local i = 1
  while i <= #args do
    if args[i] == "--auto" then opts.auto = true
    elseif args[i] == "--reboot" then reboot = true
    elseif args[i] == "--source" then i = i + 1 sourceDir = args[i]
    elseif args[i] == "--usecase" then i = i + 1 opts.usecase = args[i]
    elseif args[i] == "usecases" then opts.list = true end
    i = i + 1
  end
end

if sourceDir then
  req("tsr.config").set("pkg.sources", { { name = "mirror", type = "dir", path = sourceDir } }, "user")
end

if opts.list then
  local usecases = req("tsr.setup.usecases")
  local probe = req("tsr.hw").probe()
  local profile = req("tsr.config").get("system.profile")
  local group
  for _, u in ipairs(usecases.available(probe, profile)) do
    if u.group ~= group then group = u.group print(group .. ":") end
    print(("  %-16s %s%s"):format(u.id, u.label, u.blocked and ("   [not here: " .. u.blocked .. "]") or ""))
  end
  return
end

local ok, result = pcall(wizard.run, opts)
if not opts.auto then
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end
if not ok then
  if result == "Terminated" then return print("Setup cancelled.") end
  printError("Setup failed: " .. tostring(result))
  return
end
if result == "reboot" or (opts.auto and reboot) then
  print("Rebooting...")
  sleep(0.5)
  os.reboot()
elseif result == "quit" then
  print("Setup cancelled. Run tsr-setup to start again.")
else
  print("Setup finished.")
end
