-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Services: dhclient (configures every interface marked `dhcp = true` in the network configuration) and dhcpd (the server).
local socket = require("tsr.inet.socket")
local client = require("tsr.dhcp.client")
local serverMod = require("tsr.dhcp.server")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("dhcp")

local M = {}

local function waitForStack()
  while true do
    local ok, stack = pcall(socket.default)
    if ok then return stack end
    os.sleep(1)
  end
end

local function wanted(stack)
  local list = {}
  for name, want in pairs(stack.dhcpWanted or {}) do if want and stack.ifaces[name] then list[#list + 1] = name end end
  table.sort(list)
  return list
end

--- Client service: one thread per interface; restarts the whole set when the list of DHCP interfaces changes.
function M.client()
  local stack = waitForStack()
  while true do
    local names = wanted(stack)
    if #names == 0 then
      os.sleep(5)
    else
      local key = table.concat(names, ",")
      local jobs = {}
      for _, name in ipairs(names) do
        jobs[#jobs + 1] = function()
          client.run(stack, name, {
            hostname = stack.hostname,
            onBound = function(l) log.info("%s got %s", name, require("tsr.inet.bytes").ipStr(l.address)) end,
            onLost = function() log.warn("%s lost its lease", name) end,
            onFail = function(why) log.warn("%s: %s", name, tostring(why)) end,
          })
        end
      end
      jobs[#jobs + 1] = function()
        while table.concat(wanted(stack), ",") == key do os.sleep(5) end
      end
      parallel.waitForAny(table.unpack(jobs))
    end
  end
end

--- Relay service: /etc/tsr/inet/dhcprelay.lua = { interfaces = { "eth0" }, servers = { "10.0.0.1" } }.
function M.relayMain()
  local stack = waitForStack()
  local text = vfs.readFile("/etc/tsr/inet/dhcprelay.lua")
  if not text then log.warn("%s", "no /etc/tsr/inet/dhcprelay.lua") return end
  local chunk, err = load(text, "=dhcprelay.lua", "t", {})
  local cfg = chunk and select(2, pcall(chunk))
  if type(cfg) ~= "table" then log.error("%s", "dhcprelay.lua: " .. tostring(err or cfg)) return end
  M.relay = require("tsr.dhcp.relay").new(stack, cfg)
  M.relay:run()
end

--- Server service.
function M.serverMain()
  local stack = waitForStack()
  local text = vfs.readFile(serverMod.CONFIG)
  if not text then
    log.warn("%s", "no /etc/tsr/inet/dhcpd.lua: the DHCP server has nothing to serve")
    return
  end
  local chunk, err = load(text, "=dhcpd.lua", "t", {})
  local cfg = chunk and select(2, pcall(chunk))
  if type(cfg) ~= "table" then
    log.error("%s", "dhcpd.lua: " .. tostring(err or cfg))
    return
  end
  local server, problems = serverMod.new(stack, cfg)
  for _, p in ipairs(problems) do log.warn("%s", p) end
  server:load()
  M.server = server
  server:serve()
end

return M
