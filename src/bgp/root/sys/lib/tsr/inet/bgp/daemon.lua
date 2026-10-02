-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The bgpd service (configuration in /etc/tsr/inet/bgp.lua, see tsr.inet.bgp).
local socket = require("tsr.inet.socket")
local bgp = require("tsr.inet.bgp")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("bgp")

local M = {}

M.CONFIG = "/etc/tsr/inet/bgp.lua"

function M.main()
  local stack
  while true do
    local ok, s = pcall(socket.default)
    if ok then stack = s break end
    os.sleep(1)
  end
  local text = vfs.readFile(M.CONFIG)
  if not text then log.warn("%s", "no /etc/tsr/inet/bgp.lua") return end
  local chunk, err = load(text, "=bgp.lua", "t", {})
  local cfg
  if chunk then local ok, value = pcall(chunk) cfg = ok and value or nil err = err or value end
  if type(cfg) ~= "table" then log.error("%s", "bgp.lua: " .. tostring(err)) return end
  stack.forwarding = true
  local ok, speaker = pcall(bgp.new, stack, cfg)
  if not ok then log.error("%s", tostring(speaker)) return end
  M.speaker = speaker
  local jobs, e2 = speaker:workers()
  if not jobs then log.error("%s", tostring(e2)) return end
  log.info("%s", ("BGP running as AS%d with %d neighbour(s)"):format(speaker.as, #speaker.peerList))
  parallel.waitForAny(table.unpack(jobs))
end

return M
