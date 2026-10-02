-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The dhcp command:
--   dhcp status             what each interface got from DHCP (address, router, DNS, time left)
--   dhcp renew [iface]      ask for the address again now           dhcp release [iface]   give it back
--   dhcp leases             (server) who has which address         dhcp config   show the server configuration file
local B = require("tsr.inet.bytes")
local client = require("tsr.dhcp.client")

local M = {}

local function defaultCtx(ctx)
  ctx = ctx or {}
  if not ctx.say then
    ctx.say = function(t) print(t) end
    ctx.err = function(t) print(t) end
  end
  ctx.err = ctx.err or ctx.say
  if not ctx.stack then
    local ok, stack = pcall(function() return require("tsr.inet.socket").default() end)
    if not ok then ctx.err(tostring(stack)) return nil end
    ctx.stack = stack
  end
  return ctx
end

local function fmtTime(s)
  s = math.max(0, math.floor(s))
  if s >= 3600 then return ("%dh%02dm"):format(math.floor(s / 3600), math.floor(s / 60) % 60) end
  if s >= 60 then return ("%dm%02ds"):format(math.floor(s / 60), s % 60) end
  return s .. "s"
end

function M.run(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  local stack = ctx.stack
  local sub = args[1] or "status"
  if sub == "status" then
    local any = false
    for _, iface in ipairs(stack.ifaceList) do
      local l = iface.lease
      if l then
        any = true
        ctx.say(("%s: %s/%d from %s, lease %s left"):format(iface.name, B.ipStr(l.address), B.maskToPrefix(B.ipStr(l.mask)) or 24, B.ipStr(l.server or 0),
          fmtTime(l.obtained + l.leaseTime - stack.clock())))
        if #l.routers > 0 then ctx.say("    router " .. B.ipStr(l.routers[1])) end
        if #l.dns > 0 then
          local d = {}
          for _, x in ipairs(l.dns) do d[#d + 1] = B.ipStr(x) end
          ctx.say("    dns " .. table.concat(d, ", ") .. (l.domain and (" (domain " .. l.domain .. ")") or ""))
        end
      elseif stack.dhcpWanted and stack.dhcpWanted[iface.name] then
        any = true
        ctx.say(iface.name .. ": waiting for a DHCP server")
      end
    end
    if not any then ctx.say("no interface uses DHCP") end
    return true
  elseif sub == "renew" then
    local ifname = args[2]
    local targets = {}
    for _, iface in ipairs(stack.ifaceList) do if iface.kind ~= "loopback" and (not ifname or iface.name == ifname) then targets[#targets + 1] = iface.name end end
    if #targets == 0 then ctx.err("no such interface") return false end
    local all = true
    for _, name in ipairs(targets) do
      local lease, why = client.acquire(stack, name, { tries = 3 })
      if lease then client.apply(stack, name, lease) ctx.say(name .. ": " .. B.ipStr(lease.address))
      else ctx.err(name .. ": " .. tostring(why)) all = false end
    end
    return all
  elseif sub == "release" then
    local done = false
    for _, iface in ipairs(stack.ifaceList) do
      if iface.lease and (not args[2] or args[2] == iface.name) then client.release(stack, iface.name) ctx.say(iface.name .. ": address released") done = true end
    end
    if not done then ctx.err("nothing to release") end
    return done
  elseif sub == "leases" then
    local server = ctx.server or require("tsr.dhcp.daemon").server
    if not server then ctx.err("the DHCP server is not running here") return false end
    local list = server:active()
    if #list == 0 then ctx.say("no active leases") return true end
    for _, l in ipairs(list) do ctx.say(("%-15s %s  %s left  (%s)"):format(B.ipStr(l.ip), B.macStr(l.mac), fmtTime(l.expires - server.clock()), l.pool or "?")) end
    return true
  elseif sub == "config" then
    local vfs = require("tsr.vfs")
    local text = vfs.readFile(require("tsr.dhcp.server").CONFIG)
    ctx.say(text or "no server configuration (/etc/tsr/inet/dhcpd.lua)")
    return text ~= nil
  end
  ctx.err("usage: dhcp status | renew [iface] | release [iface] | leases | config")
  return false
end

return M
