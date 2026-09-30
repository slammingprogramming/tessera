-- SPDX-License-Identifier: AGPL-3.0-or-later
-- tresume: continue the job that was interrupted (unload, reboot, crash). `tresume --cancel` forgets it instead.
local req = (rawget(_G, "tsr") and tsr.require) or dofile("/sys/lib/tsr/loader.lua").require
if not turtle then return printError("tresume only runs on a turtle.") end
local T = req("tsr.turtle")
local j = T.job.get()
if not j then return print("There is no interrupted job.") end
if ({ ... })[1] == "--cancel" then
  T.job.finish()
  return print("Forgot the job '" .. j.name .. "'.")
end
if not j.cmd or not j.cmd[1] then return printError("The saved job has no restart command; use --cancel.") end
local prog = "/usr/bin/" .. j.cmd[1] .. ".lua"
if not fs.exists(prog) then prog = "/sys/bin/" .. j.cmd[1] .. ".lua" end
if not fs.exists(prog) then return printError("Cannot find the program '" .. j.cmd[1] .. "'. Install it or use --cancel.") end
print("Resuming " .. j.name .. "...")
os.run(setmetatable({ shell = shell, multishell = multishell }, { __index = _G }), prog, table.unpack(j.cmd, 2))
