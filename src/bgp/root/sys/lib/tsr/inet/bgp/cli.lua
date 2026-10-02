-- SPDX-License-Identifier: AGPL-3.0-or-later
-- routectl bgp ...:
--   status               AS number, router ID, sessions up
--   neighbors            every neighbour: state, relationship, prefixes received/accepted/filtered, last problem
--   routes [prefix]      the best routes (> marks the one in use, with the AS path and who told us)
--   adj-in|adj-out <ip>  what a neighbour sent us / what we sent it
--   clear <ip>           reset a session
--   log                  recent events
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.bgp.wire")

local M = {}

local function pathText(p)
  if #p == 0 then return "i" end
  return table.concat(p, " ")
end

function M.run(args, ctx)
  local bgp = ctx.bgp or require("tsr.inet.bgp.daemon").speaker
  if not bgp then ctx.err("BGP is not running on this computer (service bgpd)") return false end
  local sub = args[1] or "status"
  local now = bgp.stack.clock()
  if sub == "status" then
    ctx.say(("AS%d, router ID %s, %d of %d session(s) established"):format(bgp.as, B.ipStr(bgp.routerId), bgp:established(), #bgp.peerList))
    ctx.say(("%d route(s) in the table; updates received %d, rejected %d, origin validation failures %d"):format(#bgp:routeList(), bgp.stats.updatesIn, bgp.stats.rejected, bgp.stats.hijacks))
    return true
  elseif sub == "neighbors" or sub == "neighbours" or sub == "summary" then
    ctx.say(("%-16s %-7s %-10s %-12s %5s %5s %5s  %s"):format("neighbor", "AS", "relation", "state", "rcvd", "acc", "filt", "up for / last problem"))
    for _, p in ipairs(bgp.peerList) do
      ctx.say(("%-16s %-7d %-10s %-12s %5d %5d %5d  %s"):format(B.ipStr(p.ip), p.as, p.rel, p.state, p.stats.received, p.stats.accepted, p.stats.filtered,
        p.state == "Established" and (math.floor(now - (p.since or now)) .. "s") or tostring(p.lastError or "-")))
    end
    return true
  elseif sub == "routes" then
    local want
    if args[2] then
      local net, plen = B.cidr(args[2])
      if not net then ctx.err("bad prefix") return false end
      want = net .. "/" .. plen
    end
    for _, r in ipairs(bgp:routeList()) do
      if not want or (r.net .. "/" .. r.plen) == want then
        ctx.say(("*> %-18s %-15s lp %-4d path %s%s"):format(B.cidrStr(r.net, r.plen), r.local_ and "0.0.0.0" or B.ipStr(r.nextHop), r.localPref, pathText(r.asPath),
          r.local_ and "  (originated here)" or (r.peer and ("  from " .. B.ipStr(r.peer.ip) .. " (" .. r.peer.rel .. ")") or "")))
      end
    end
    return true
  elseif sub == "adj-in" or sub == "adj-out" then
    local peer = bgp.peers[B.ip(args[2] or "")]
    if not peer then ctx.err("no such neighbor") return false end
    local keys = {}
    for k in pairs(sub == "adj-in" and peer.adjIn or peer.adjOut) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local r = (sub == "adj-in" and peer.adjIn or peer.adjOut)[k]
      local path = r.asPath or (r.attrs and r.attrs.asPath) or {}
      ctx.say(("%-18s path %s"):format(B.cidrStr(r.net, r.plen), pathText(path)))
    end
    return true
  elseif sub == "clear" then
    if not bgp:clear(args[2] or "") then ctx.err("no such neighbor") return false end
    ctx.say("session reset")
    return true
  elseif sub == "log" then
    for _, l in ipairs(bgp.log) do ctx.say(l) end
    return true
  end
  ctx.err("usage: routectl bgp status | neighbors | routes [prefix] | adj-in <ip> | adj-out <ip> | clear <ip> | log")
  return false
end

return M
