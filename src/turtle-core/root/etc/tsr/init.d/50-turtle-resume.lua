-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Boot daemon: a turtle that was unloaded in the middle of a job carries on with it after it restarts.
-- Disable with:  config set turtle.auto_resume false   (in /etc/tsr/system.cfg: turtle = { auto_resume = false })
if not rawget(_G, "turtle") then return end
local config = require("tsr.config")
if config.get("turtle.auto_resume", true) == false then return end
local T = require("tsr.turtle")
local log = require("tsr.log").get("turtle")

T.load()
local j = T.job.get()
if not j or not j.cmd or not j.cmd[1] then return end

local prog = "/usr/bin/" .. j.cmd[1] .. ".lua"
if not fs.exists(prog) then prog = "/sys/bin/" .. j.cmd[1] .. ".lua" end
if not fs.exists(prog) then
  log.warn("interrupted job '%s' cannot be resumed: program %s is missing", j.name, j.cmd[1])
  return
end

sleep(2) -- let the shell come up first so its output does not get in the way
log.info("resuming job '%s'", j.name)
local args = { table.unpack(j.cmd, 2) }
require("tsr.kernel").spawn({
  name = "resume:" .. j.name, session = true,
  fn = function()
    print("Resuming " .. j.name .. "... (Ctrl+T to stop; `tresume --cancel` forgets the job)")
    os.run({}, prog, table.unpack(args))
  end,
})
