-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The ripd service: routing information protocol for the networks of this router (configuration in /etc/tsr/inet/rip.lua).
local socket = require("tsr.inet.socket")
local rip = require("tsr.inet.route.rip")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("rip")

local M = {}

M.CONFIG = "/etc/tsr/inet/rip.lua"

function M.rip()
  local stack
  while true do
    local ok, s = pcall(socket.default)
    if ok then stack = s break end
    os.sleep(1)
  end
  local cfg = {}
  local text = vfs.readFile(M.CONFIG)
  if text then
    local chunk, err = load(text, "=rip.lua", "t", {})
    local ok, value = false, err
    if chunk then ok, value = pcall(chunk) end
    if not ok or type(value) ~= "table" then log.error("%s", "rip.lua: " .. tostring(value)) return end
    cfg = value
  end
  stack.forwarding = true
  local r = rip.new(stack, cfg)
  M.daemon = r
  local jobs, err = r:workers()
  if not jobs then log.error("%s", tostring(err)) return end
  log.info("%s", "RIP running")
  parallel.waitForAny(table.unpack(jobs))
end

return M
