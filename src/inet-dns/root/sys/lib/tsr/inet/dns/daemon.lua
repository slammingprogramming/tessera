-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The named service: loads /etc/tsr/inet/named.lua and answers queries.
local socket = require("tsr.inet.socket")
local serverMod = require("tsr.inet.dns.server")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("named")

local M = {}

function M.main()
  local stack
  while true do
    local ok, s = pcall(socket.default)
    if ok then stack = s break end
    os.sleep(1)
  end
  local text = vfs.readFile(serverMod.CONFIG)
  local cfg = {}
  if text then
    local chunk, err = load(text, "=named.lua", "t", {})
    local ok, value = false, err
    if chunk then ok, value = pcall(chunk) end
    if not ok or type(value) ~= "table" then log.error("%s", "named.lua: " .. tostring(value)) return end
    cfg = value
  else
    log.warn("%s", "no /etc/tsr/inet/named.lua: serving no zones")
  end
  local server = serverMod.new(stack, cfg)
  for _, p in ipairs(server:loadZones()) do log.warn("%s", p) end
  M.server = server
  local jobs, err = server:workers(3)
  if not jobs then log.error("%s", tostring(err)) return end
  parallel.waitForAny(table.unpack(jobs))
end

return M
