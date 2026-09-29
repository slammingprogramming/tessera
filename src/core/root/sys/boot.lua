-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Tessera boot. Loaded by /startup.lua in the startup context (so `shell` and `multishell` are visible here).
-- Returns the action for stage 0: "craftos" (leave to the plain shell), "shutdown" or "reboot".
local loader = dofile("/sys/lib/tsr/loader.lua")
local require = loader.require

local config = require("tsr.config")
local log = require("tsr.log")
local vfs = require("tsr.vfs")
local power = require("tsr.power")

local BOOT_COUNT = "/var/lib/tsr/boot.count"

-- 1. Configuration and logging -----------------------------------------------------------------------------------
config.setDefaults(require("tsr.defaults"))
config.loadAll()
log.setLevel(config.get("log.level", "info"))
log.setFile(config.get("log.file"), config.get("log.max_size"))
local blog = log.get("boot")
blog.info("booting %s %s", require("tsr.version").name, require("tsr.version").version)

-- 2. Repair anything a chunk-unload interrupted ------------------------------------------------------------------
local repaired = 0
for _, dir in ipairs({ "/etc", "/var", "/sys", "/usr" }) do
  if fs.isDir(dir) then repaired = repaired + vfs.recover(dir) end
end
if repaired > 0 then blog.warn("recovered %d interrupted file write(s)", repaired) end

-- 2b. Finish or roll back an interrupted package transaction (only when the package manager is installed)
if fs.exists("/sys/lib/tsr/pkg/init.lua") then
  local ok, res = pcall(function() return require("tsr.pkg").recover() end)
  if not ok then blog.warn("package recovery failed: %s", tostring(res))
  elseif res then blog.warn("package transaction %s", res) end
end

-- 3. File system: mounts, RAM disk ---------------------------------------------------------------------------------
vfs.install()
local tmpSize = config.get("fs.tmp_size", 0)
if tmpSize > 0 and not fs.exists("/tmp") then vfs.mount("/tmp", vfs.ramfs(tmpSize)) end

-- 4. Power hooks, global API, CraftOS package path ---------------------------------------------------------------
power.install()
_G.tsr = require("tsr.sys")
pcall(function()
  if not settings.get("shell.package_path") then
    settings.set("shell.package_path",
      "?;?.lua;?/init.lua;/sys/lib/?.lua;/sys/lib/?/init.lua;/usr/lib/?.lua;/usr/lib/?/init.lua;" ..
      "/rom/modules/main/?;/rom/modules/main/?.lua;/rom/modules/main/?/init.lua")
    -- deliberately not saved: the setting only lives for this boot
  end
end)

-- 5. Let the CraftOS shell find Tessera's programs ----------------------------------------------------------------
local parentShell = rawget(_ENV or _G, "shell")
if parentShell and parentShell.path then
  local p = parentShell.path()
  if not p:find("/usr/bin", 1, true) then parentShell.setPath(p .. ":/usr/bin:/sys/bin") end
end

-- 6. Run ---------------------------------------------------------------------------------------------------------
local stableAfter = config.get("boot.stable_after", 5)
local action = require("tsr.init").run({
  parentShell = parentShell,
  onReady = function()
    -- a boot only counts as good once the system has stayed up for a few seconds
    require("tsr.kernel").spawn({
      name = "boot-watch", window = false, daemon = true,
      fn = function()
        local t = os.startTimer(stableAfter)
        repeat local _, id = os.pullEvent("timer") until id == t
        vfs.writeFile(BOOT_COUNT, "0")
        blog.debug("boot marked stable")
      end,
    })
  end,
})

blog.info("kernel stopped, action=%s", tostring(action))
return action
