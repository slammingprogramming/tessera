-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Power management: shutdown/reboot hooks, so services can flush state before the computer stops even when a program
-- calls os.shutdown()/os.reboot() directly (e.g. the stock `shutdown` command).
local log = require("tsr.log").get("power")

local M = {}

local hooks = {}
local rawShutdown, rawReboot = os.shutdown, os.reboot
local installed = false

--- Register fn(action) to run before power-off/reboot; action is "shutdown" or "reboot".
function M.onPower(fn) hooks[#hooks + 1] = fn end

local function runHooks(action)
  for _, fn in ipairs(hooks) do
    local ok, err = pcall(fn, action)
    if not ok then log.warn("power hook failed: %s", tostring(err)) end
  end
end

function M.shutdown()
  runHooks("shutdown")
  rawShutdown()
end

function M.reboot()
  runHooks("reboot")
  rawReboot()
end

--- Route os.shutdown / os.reboot through the hooks. Idempotent.
function M.install()
  if installed then return end
  installed = true
  os.shutdown = M.shutdown
  os.reboot = M.reboot
end

function M.uninstall()
  if not installed then return end
  installed = false
  os.shutdown, os.reboot = rawShutdown, rawReboot
end

return M
