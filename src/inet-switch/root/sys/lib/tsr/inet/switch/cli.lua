-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The swctl command (management of the switch running on this computer):
--   swctl show [ports|vlan|mac|stp|neighbors|status]
--   swctl port <name> access <vlan>          | trunk [allowed 10,20] [native <vlan>]   | enable | disable
--   swctl port <name> security <max> [shutdown|restrict|protect] | security off | storm <packets/s> | storm off | cost <n>
--   swctl vlan add <id> [name] | vlan del <id>
--   swctl mac add <vlan> <mac> <port> | mac flush [port]
--   swctl mirror <dest-port> <source,source...> | mirror off
--   swctl svi <vlan> <a.b.c.d/n>            (an IP interface of the switch in a VLAN)
--   swctl stp on|off | stp priority <n>
--   swctl save                               write the running configuration to /etc/tsr/inet/switch.lua
local B = require("tsr.inet.bytes")
local config = require("tsr.inet.config")
local vfs = require("tsr.vfs")

local M = {}

M.CONFIG = "/etc/tsr/inet/switch.lua"

local function defaultCtx(ctx)
  ctx = ctx or {}
  if not ctx.say then
    ctx.say = function(t) print(t) end
    ctx.err = function(t) print(t) end
  end
  ctx.err = ctx.err or ctx.say
  if not ctx.switch then
    local ok, daemon = pcall(require, "tsr.inet.switch.daemon")
    ctx.switch = ok and daemon.switch or nil
  end
  if not ctx.switch then ctx.err("the switch is not running on this computer (service switchd)") return nil end
  return ctx
end

local function isAdmin(ctx)
  local okAuth, auth = pcall(require, "tsr.auth")
  if not okAuth or not auth.hasUsers() then return true end
  local me = auth.current()
  if me == nil or auth.can(me, "auth.manage") then return true end
  ctx.err("only administrators can change the switch")
  return false
end

local function list(text)
  local t = {}
  for n in tostring(text):gmatch("[^,]+") do t[#t + 1] = tonumber(n) or n end
  return t
end

--- The running configuration as a table that M.CONFIG can hold.
function M.snapshot(sw)
  local cfg = { name = sw.name, aging = sw.aging, ports = {}, vlans = {}, svis = {}, lldp = sw.lldp or nil }
  for _, p in ipairs(sw.portList) do
    local c = { mode = p.mode }
    if p.mode == "access" then c.vlan = p.vlan else
      c.native = p.native ~= 1 and p.native or nil
      if p.allowed then
        c.allowed = {}
        for v in pairs(p.allowed) do c.allowed[#c.allowed + 1] = v end
        table.sort(c.allowed)
      end
    end
    if p.secure then c.secure = p.secure end
    if p.storm then c.storm = p.storm end
    if p.stp and p.stp.cost ~= 19 then c.cost = p.stp.cost end
    cfg.ports[p.name] = c
  end
  for id, name in pairs(sw.vlans) do if id ~= 1 then cfg.vlans[id] = name end end
  for vlan, iface in pairs(sw.svis) do
    local a = iface.addrs[1]
    if a then cfg.svis[vlan] = B.ipStr(a.ip) .. "/" .. a.plen end
  end
  if sw.stp then cfg.stp = { enabled = sw.stp.enabled, priority = sw.stp.priority } else cfg.stp = false end
  if sw.mirror then
    local sources = {}
    for s in pairs(sw.mirror.sources) do sources[#sources + 1] = s end
    table.sort(sources)
    cfg.mirror = { dest = sw.mirror.dest, sources = sources, direction = sw.mirror.direction }
  end
  return cfg
end

function M.run(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  local sw = ctx.switch
  local sub = args[1] or "show"
  if sub == "show" then
    local what = args[2] or "status"
    if what == "ports" or what == "status" then
      ctx.say(("%-8s %-7s %-6s %-12s %7s %7s  %s"):format("port", "mode", "vlan", "state", "rx", "tx", "notes"))
      for _, p in ipairs(sw.portList) do
        local state = p.errdisabled and "err-disabled" or (not p.up and "down") or (p.stp and sw.stp and sw.stp.enabled and p.stp.state) or "forwarding"
        local vlan = p.mode == "access" and tostring(p.vlan) or (p.allowed and (function() local t = {} for v in pairs(p.allowed) do t[#t + 1] = v end table.sort(t) return table.concat(t, ",") end)() or "all")
        local notes = {}
        if p.secure then notes[#notes + 1] = "secure" end
        if p.storm then notes[#notes + 1] = "storm " .. p.storm .. "/s" end
        if sw.mirror and sw.mirror.dest == p.name then notes[#notes + 1] = "mirror" end
        if p.counters.violations > 0 then notes[#notes + 1] = p.counters.violations .. " violation(s)" end
        ctx.say(("%-8s %-7s %-6s %-12s %7d %7d  %s"):format(p.name, p.mode, vlan, state, p.counters.rx, p.counters.tx, table.concat(notes, ", ")))
      end
      return true
    elseif what == "vlan" or what == "vlans" then
      local ids = {}
      for id in pairs(sw.vlans) do ids[#ids + 1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do
        local members = {}
        for _, p in ipairs(sw.portList) do
          if p.mode == "access" and p.vlan == id then members[#members + 1] = p.name
          elseif p.mode == "trunk" and (p.allowed == nil or p.allowed[id] or id == p.native) then members[#members + 1] = p.name .. "(t)" end
        end
        local svi = sw.svis[id] and sw.svis[id].addrs[1]
        ctx.say(("%-5d %-12s %s%s"):format(id, sw.vlans[id], table.concat(members, " "), svi and ("   svi " .. B.ipStr(svi.ip) .. "/" .. svi.plen) or ""))
      end
      return true
    elseif what == "mac" then
      for _, r in ipairs(sw:macTable()) do ctx.say(("%-5d %s  %-6s %s"):format(r.vlan, B.macStr(r.mac), r.port, r.static and "static" or (r.age .. "s"))) end
      return true
    elseif what == "stp" then
      if not sw.stp then ctx.say("spanning tree is off") return true end
      for _, l in ipairs(sw.stp:describe()) do ctx.say(l) end
      return true
    elseif what == "neighbors" or what == "neighbours" then
      local n = sw:neighbourList()
      if #n == 0 then ctx.say("no neighbours seen") end
      for _, x in ipairs(n) do ctx.say(("%-8s %s port %s (%s)"):format(x.port, x.name or "?", x.remotePort or "?", x.chassis and B.macStr(x.chassis) or "?")) end
      return true
    end
    ctx.err("usage: swctl show ports|vlan|mac|stp|neighbors")
    return false
  end
  if not isAdmin(ctx) then return false end
  if sub == "port" then
    local name, action = args[2], args[3]
    if not (name and sw.ports[name]) then ctx.err("no such port: " .. tostring(name)) return false end
    local function done(p, err) if not p then ctx.err(tostring(err)) return false end return true end
    if action == "access" then
      local vlan = tonumber(args[4])
      if not vlan then ctx.err("usage: swctl port <name> access <vlan>") return false end
      sw.vlans[vlan] = sw.vlans[vlan] or ("vlan" .. vlan)
      return done(sw:configurePort(name, { mode = "access", vlan = vlan }))
    elseif action == "trunk" then
      local ch = { mode = "trunk", allowed = false }
      local i = 4
      while args[i] do
        if args[i] == "allowed" then ch.allowed = list(args[i + 1] or "") i = i + 2
        elseif args[i] == "native" then ch.native = tonumber(args[i + 1]) i = i + 2
        else ctx.err("unknown trunk option " .. args[i]) return false end
      end
      return done(sw:configurePort(name, ch))
    elseif action == "enable" or action == "disable" then
      sw:setPortEnabled(name, action == "enable")
      return true
    elseif action == "security" then
      if args[4] == "off" then return done(sw:configurePort(name, { secure = false })) end
      local max = tonumber(args[4])
      if not max then ctx.err("usage: swctl port <name> security <max> [shutdown|restrict|protect]") return false end
      return done(sw:configurePort(name, { secure = { max = max, violation = args[5] or "restrict" } }))
    elseif action == "storm" then
      if args[4] == "off" then return done(sw:configurePort(name, { storm = false })) end
      return done(sw:configurePort(name, { storm = tonumber(args[4]) }))
    elseif action == "cost" then
      return done(sw:configurePort(name, { cost = tonumber(args[4]) }))
    end
    ctx.err("usage: swctl port <name> access|trunk|enable|disable|security|storm|cost ...")
    return false
  elseif sub == "vlan" then
    local id = tonumber(args[3])
    if args[2] == "add" and id and id >= 1 and id <= 4094 then sw.vlans[id] = args[4] or ("vlan" .. id) return true end
    if args[2] == "del" and id and id ~= 1 then
      for _, p in ipairs(sw.portList) do if p.mode == "access" and p.vlan == id then ctx.err("ports still use VLAN " .. id) return false end end
      sw.vlans[id] = nil
      return true
    end
    ctx.err("usage: swctl vlan add <id> [name] | vlan del <id>")
    return false
  elseif sub == "mac" then
    if args[2] == "flush" then sw:flushPort(args[3]) return true end
    if args[2] == "add" then
      local vlan, mac, port = tonumber(args[3]), B.mac(args[4] or ""), args[5]
      if not (vlan and mac and port and sw.ports[port]) then ctx.err("usage: swctl mac add <vlan> <mac> <port>") return false end
      sw:addStatic(vlan, mac, port)
      return true
    end
    ctx.err("usage: swctl mac add <vlan> <mac> <port> | mac flush [port]")
    return false
  elseif sub == "mirror" then
    if args[2] == "off" then sw:setMirror(nil) return true end
    local ok, err = sw:setMirror(args[2], list(args[3] or ""))
    if not ok then ctx.err(tostring(err)) return false end
    return true
  elseif sub == "svi" then
    local vlan = tonumber(args[2])
    if not (vlan and args[3] and args[3]:match("^[%d%.]+/%d+$")) then ctx.err("usage: swctl svi <vlan> <a.b.c.d/n>") return false end
    sw:addSvi(vlan, args[3])
    return true
  elseif sub == "stp" then
    if not sw.stp then ctx.err("this switch was started without spanning tree") return false end
    if args[2] == "on" then sw.stp.enabled = true sw.stp:start() return true end
    if args[2] == "off" then sw.stp.enabled = false sw.stp:stop() return true end
    if args[2] == "priority" and tonumber(args[3]) then
      sw.stp.priority = tonumber(args[3])
      sw.stp.bridgeId = B.u16(sw.stp.priority) .. sw.mac
      sw.stp:recompute()
      return true
    end
    ctx.err("usage: swctl stp on|off|priority <n>")
    return false
  elseif sub == "save" then
    local ok, err = vfs.writeFile(M.CONFIG, "-- SPDX-License-Identifier: AGPL-3.0-or-later\n-- Switch configuration (written by `swctl save`).\nreturn " .. config.dump(M.snapshot(sw)) .. "\n")
    if not ok then ctx.err("could not save: " .. tostring(err)) return false end
    ctx.say("saved to " .. M.CONFIG)
    return true
  end
  ctx.err("usage: swctl show | port | vlan | mac | mirror | svi | stp | save")
  return false
end

return M
