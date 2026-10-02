-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The netfilter service: installs the packet filter on the network stack and loads /etc/tsr/inet/iptables.rules.
local socket = require("tsr.inet.socket")
local fwMod = require("tsr.inet.fw")
local iptables = require("tsr.inet.fw.iptables")
local cli = require("tsr.inet.fw.cli")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("netfilter")

local M = {}

function M.main()
  local stack
  while true do
    local ok, s = pcall(socket.default)
    if ok then stack = s break end
    os.sleep(1)
  end
  local fw = fwMod.install(stack)
  local text = vfs.readFile(cli.RULES)
  if text then
    for _, p in ipairs(iptables.load(fw, text)) do log.warn("%s", p) end
    log.info("%s", "firewall rules loaded")
  else
    log.info("%s", "no saved rules: the firewall accepts everything (use iptables, then iptables-save)")
  end
  while true do os.sleep(60) end
end

return M
