-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The inetd service: creates the network stack of this computer, applies /etc/tsr/inet/network.lua, and then keeps it alive: modem messages go
-- in, timers tick, and modems that are plugged in or removed are picked up. Other services (dhcpd, dnsd, httpd, ...) use the stack through
-- tsr.inet.socket in their own processes.
local Stack = require("tsr.inet.stack")
local socket = require("tsr.inet.socket")
local config = require("tsr.inet.config")
local link = require("tsr.inet.link")
local log = require("tsr.log").get("inet")

local M = {}

M.TICK = 0.1

--- Build the stack from the configuration. Separate from main() so that it can be tested.
function M.create(cfg)
  local stack = Stack.new({ clock = os.clock, hostname = cfg.hostname or os.getComputerLabel() or ("cc" .. os.getComputerID()) })
  stack.daemon = true
  stack.logger = function(text) log.warn("%s", text) end
  stack.onWake = function() os.queueEvent("inet_wake") end
  return stack
end

--- Hotplug: attach interfaces for modems that appeared since the last look (only in automatic mode) and drop those that vanished.
function M.rescan(stack, cfg)
  local present = {}
  for _, m in ipairs(config.detectModems()) do present[m.name] = true end
  for i = #link.drivers, 1, -1 do
    local d = link.drivers[i]
    if not present[d.name] then
      log.info("%s", "modem " .. tostring(d.name) .. " went away: interface " .. d.iface.name .. " is down")
      stack:setUp(d.iface.name, false)
      d.gone = true
    elseif d.gone then
      d.gone = nil
      stack:setUp(d.iface.name, true)
    end
  end
  if cfg.auto then
    local auto = config.automatic()
    for name, spec in pairs(auto.interfaces) do
      local known = false
      for _, d in ipairs(link.drivers) do if d.name == spec.modem then known = true end end
      if not known then
        local problems = config.apply(stack, { interfaces = { [name] = spec } })
        for _, p in ipairs(problems) do log.warn("%s", p) end
      end
    end
  end
end

function M.main()
  local cfg, err = config.load()
  if not cfg then
    log.error("%s", tostring(err))
    cfg = {}
  end
  if not cfg.interfaces or next(cfg.interfaces) == nil then
    cfg = config.automatic()
    cfg.hostname = nil
  end
  local stack = M.create(cfg)
  socket.setDefault(stack)
  for _, p in ipairs(config.apply(stack, cfg)) do log.warn("%s", p) end
  local hasDns, dnsClient = pcall(require, "tsr.inet.dns.client")
  if hasDns then dnsClient.install(stack) end
  log.info("%s", "network stack up: " .. #stack.ifaceList - 1 .. " interface(s)")
  os.queueEvent("inet_up")
  local timer = os.startTimer(M.TICK)
  while true do
    local ev = { os.pullEventRaw() }
    local name = ev[1]
    if name == "modem_message" then
      link.dispatch(ev)
    elseif name == "timer" and ev[2] == timer then
      stack:tick()
      timer = os.startTimer(M.TICK)
    elseif name == "peripheral" or name == "peripheral_detach" then
      M.rescan(stack, cfg)
    elseif name == "terminate" then
      break
    end
    if stack.eventHooks then for _, h in ipairs(stack.eventHooks) do pcall(h, ev) end end
  end
  for i = #link.drivers, 1, -1 do link.detach(link.drivers[i].iface.name) end
  socket.setDefault(nil)
end

return M
