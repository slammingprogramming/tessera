-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The routectl command:
--   routectl rip status | routes | neighbors          what RIP knows
--   routectl bgp status | neighbors | routes | ...     (see the bgp package)
--   routectl show                                      the whole routing table with where each route came from
local B = require("tsr.inet.bytes")

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

function M.run(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  local sub = args[1] or "show"
  if sub == "show" then
    local list = {}
    for _, r in ipairs(ctx.stack.routes) do list[#list + 1] = r end
    table.sort(list, function(a, b) if a.plen ~= b.plen then return a.plen > b.plen end return a.net < b.net end)
    for _, r in ipairs(list) do
      ctx.say(("%-18s %-15s %-8s %-10s metric %d"):format(r.plen == 0 and "default" or B.cidrStr(r.net, r.plen), r.gateway and B.ipStr(r.gateway) or "-", r.iface, r.proto, r.metric))
    end
    return true
  elseif sub == "rip" then
    local rip = ctx.rip or require("tsr.inet.route.daemon").daemon
    if not rip then ctx.err("RIP is not running on this computer (service ripd)") return false end
    local what = args[2] or "status"
    if what == "routes" then
      for _, l in ipairs(rip:describe()) do ctx.say(l) end
    elseif what == "neighbors" or what == "neighbours" then
      local any = false
      for ip, n in pairs(rip.neighbours) do any = true ctx.say(("%-15s on %-6s last heard %ds ago"):format(B.ipStr(ip), n.iface, math.floor(ctx.stack.clock() - n.last))) end
      if not any then ctx.say("no RIP neighbours heard") end
    else
      ctx.say(("RIP: sent %d, received %d, rejected %d, triggered updates %d, %d learned route(s)"):format(rip.stats.sent, rip.stats.received, rip.stats.rejected, rip.stats.triggered, #rip:describe()))
    end
    return true
  elseif sub == "bgp" then
    local ok, bgp = pcall(require, "tsr.inet.bgp.cli")
    if not ok then ctx.err("the bgp package is not installed") return false end
    return bgp.run({ table.unpack(args, 2) }, ctx)
  end
  ctx.err("usage: routectl show | rip [status|routes|neighbors] | bgp ...")
  return false
end

return M
