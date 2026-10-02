-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The switchd service: starts the switch from /etc/tsr/inet/switch.lua (the ports are interfaces made by the network configuration).
local socket = require("tsr.inet.socket")
local switchMod = require("tsr.inet.switch")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("switch")

local M = {}

function M.main()
  local stack
  while true do
    local ok, s = pcall(socket.default)
    if ok then stack = s break end
    os.sleep(1)
  end
  local text = vfs.readFile("/etc/tsr/inet/switch.lua")
  if not text then
    log.warn("%s", "no /etc/tsr/inet/switch.lua: nothing to switch")
    return
  end
  local chunk, err = load(text, "=switch.lua", "t", {})
  local cfg
  if chunk then local ok, value = pcall(chunk) cfg = ok and value or nil err = err or value end
  if type(cfg) ~= "table" then log.error("%s", "switch.lua: " .. tostring(err)) return end
  -- wait for the interfaces of the ports to appear (inetd creates them)
  for _ = 1, 30 do
    local missing
    for name in pairs(cfg.ports or {}) do if not stack.ifaces[name] then missing = name end end
    if not missing then break end
    os.sleep(1)
  end
  local sw = switchMod.new(stack, cfg)
  M.switch = sw
  stack.forwarding = stack.forwarding or cfg.routing == true
  sw:start()
  log.info("%s", "switch started with " .. #sw.portList .. " port(s)")
  while sw.started do os.sleep(5) end
end

return M
