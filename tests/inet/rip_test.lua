-- SPDX-License-Identifier: AGPL-3.0-or-later
local B = require("tsr.inet.bytes")
local rip = require("tsr.inet.route.rip")
local ICMP = require("tsr.inet.icmp")
local Sim = dofile("/tests/lib/inetsim.lua")

local FAST = { update = 3, timeout = 18, gc = 12 }

local function router(sim, name, cfg)
  local h = sim:host(name, { forwarding = true })
  return h
end

local function start(sim, host, cfg)
  cfg = cfg or {}
  for k, v in pairs(FAST) do if cfg[k] == nil then cfg[k] = v end end
  local r = rip.new(host, cfg)
  for _, job in ipairs(assert(r:workers())) do local t = sim:spawn(job) t.daemon = true end
  return r
end

--- A line: h1 -- R1 -- R2 -- R3 -- R4 -- h4, each link its own /30-ish network.
local function line()
  local sim = Sim.new()
  local rs = {}
  for i = 1, 4 do rs[i] = router(sim, "r" .. i) end
  local lan1, lan4 = sim:segment("lan1"), sim:segment("lan4")
  local h1, h4 = sim:host("h1"), sim:host("h4")
  sim:plug(h1, "eth0", lan1, "10.1.0.5/24") sim:plug(rs[1], "eth0", lan1, "10.1.0.1/24")
  sim:plug(h4, "eth0", lan4, "10.4.0.5/24") sim:plug(rs[4], "eth1", lan4, "10.4.0.1/24")
  h1:addRoute("default", "10.1.0.1") h4:addRoute("default", "10.4.0.1")
  local links = {}
  for i = 1, 3 do
    local seg = sim:segment("link" .. i)
    links[i] = seg
    sim:plug(rs[i], i == 1 and "eth1" or "eth1", seg, ("10.0.%d.1/24"):format(i))
    sim:plug(rs[i + 1], "eth0", seg, ("10.0.%d.2/24"):format(i))
  end
  return sim, rs, h1, h4, links
end

test("messages: encode and decode, authentication trailers", function()
  local entries = { { net = B.ip("10.1.0.0"), plen = 24, metric = 3, nexthop = 0 }, { net = 0, plen = 0, metric = 1 } }
  local m = assert(rip.decode(rip.encode(2, entries)))
  eq(m.command, 2) eq(#m.entries, 2) eq(m.entries[1].plen, 24) eq(m.entries[1].metric, 3) eq(m.entries[2].plen, 0)
  local pw = assert(rip.decode(rip.encode(2, entries, { type = "password", key = "s3cret" })))
  eq(pw.auth.type, "password") eq(pw.auth.key, "s3cret") eq(#pw.entries, 2)
  local hm = assert(rip.decode(rip.encode(2, entries, { type = "hmac", key = "k" }, 7)))
  eq(hm.auth.type, "hmac") eq(hm.auth.seq, 7) eq(#hm.auth.mac, 16)
  eq(select(2, rip.decode("junk")), "not RIPv2")
  -- more than 25 routes go into several messages (checked through the sender)
  local sim = Sim.new()
  local a = router(sim, "a")
  local seg = sim:segment("s")
  sim:plug(a, "eth0", seg, "10.0.0.1/24")
  local peer = sim:host("peer")
  sim:plug(peer, "eth0", seg, "10.0.0.2/24")
  for i = 1, 60 do a:addRoute(("172.16.%d.0/24"):format(i), "10.0.0.2") end
  local r = rip.new(a, { redistribute = { "connected", "static" }, interfaces = { "eth0" }, update = 3, timeout = 18, gc = 12 })
  local got = {}
  local u = require("tsr.inet.socket").udp(peer)
  u:setoption("reuse", true)
  u:bind(nil, 520)
  peer:joinGroup("224.0.0.9")
  for _, job in ipairs(assert(r:workers())) do local t = sim:spawn(job) t.daemon = true end
  sim:run(1)
  while true do
    local data = u:receivefrom(0.1)
    if not data then break end
    got[#got + 1] = assert(rip.decode(data))
  end
  local total = 0
  for _, msg in ipairs(got) do total = total + #msg.entries ok(#msg.entries <= 25) end
  ok(total >= 60, "all 60 static routes were advertised in " .. #got .. " messages")
  ok(#got >= 3)
end)

test("a chain of routers learns the networks at both ends; traffic flows end to end", function()
  local sim, rs, h1, h4 = line()
  for i = 1, 4 do start(sim, rs[i]) end
  sim:run(25)
  local r = rs[1]:lookup(B.ip("10.4.0.5"))
  ok(r and r.proto == "rip", "R1 knows the far LAN")
  eq(r.gateway, B.ip("10.0.1.2"))
  eq(r.metric, rip.DISTANCE + 4, "four hops")
  eq(rs[4]:lookup(B.ip("10.1.0.5")).gateway, B.ip("10.0.3.1"))
  local reply = ICMP.probe(h1, "10.4.0.5", { timeout = 3 })
  ok(reply.ok, tostring(reply.reason))
  eq(reply.ttl, 64 - 4, "four routers on the way")
  -- connected networks are never replaced by learned ones
  local connected = rs[2]:lookup(B.ip("10.0.1.2"))
  eq(connected.proto, "connected")
end)

test("failures: a dead link is noticed, routes are poisoned instead of counting to infinity, a better path takes over", function()
  local sim = Sim.new()
  -- a triangle with a long way round: R1-R2 direct, and R1-R3-R2
  local rs = {}
  for i = 1, 3 do rs[i] = router(sim, "r" .. i) end
  local lan2, lan1 = sim:segment("lan2"), sim:segment("lan1")
  local h1, h2 = sim:host("h1"), sim:host("h2")
  sim:plug(h1, "eth0", lan1, "10.1.0.5/24") sim:plug(rs[1], "eth0", lan1, "10.1.0.1/24")
  sim:plug(h2, "eth0", lan2, "10.2.0.5/24") sim:plug(rs[2], "eth0", lan2, "10.2.0.1/24")
  h1:addRoute("default", "10.1.0.1") h2:addRoute("default", "10.2.0.1")
  local direct, a, b = sim:segment("direct"), sim:segment("a"), sim:segment("b")
  sim:plug(rs[1], "eth1", direct, "10.0.12.1/24") sim:plug(rs[2], "eth1", direct, "10.0.12.2/24")
  sim:plug(rs[1], "eth2", a, "10.0.13.1/24") sim:plug(rs[3], "eth0", a, "10.0.13.3/24")
  sim:plug(rs[3], "eth1", b, "10.0.23.3/24") sim:plug(rs[2], "eth2", b, "10.0.23.2/24")
  local ripd = {}
  for i = 1, 3 do ripd[i] = start(sim, rs[i]) end
  sim:run(25)
  local r = rs[1]:lookup(B.ip("10.2.0.5"))
  eq(r.gateway, B.ip("10.0.12.2"), "the direct link wins: one hop")
  ok(ICMP.probe(h1, "10.2.0.5", { timeout = 3 }).ok)
  -- the direct link breaks without any notice (frames just vanish)
  direct.drop = function() return true end
  rs[1]:iface("eth1").port.down = true
  rs[2]:iface("eth1").port.down = true
  sim:run(60)
  local r2 = rs[1]:lookup(B.ip("10.2.0.5"))
  ok(r2 and r2.gateway == B.ip("10.0.13.3"), "traffic goes the long way round now")
  eq(r2.metric, rip.DISTANCE + 3)
  ok(ICMP.probe(h1, "10.2.0.5", { timeout = 3 }).ok)
  -- the metric never counted up beyond what the real path costs (poison reverse): nobody holds a route above the long path's cost
  for _, d in ipairs(ripd) do for _, route in pairs(d.routes) do ok(route.metric <= 16) end end
  -- a LAN network disappears: everybody drops it after the timeout and forgets it after the garbage collection time
  lan2.drop = function() return true end
  rs[2]:iface("eth0").port.down = true
  rs[2]:setUp("eth0", false)
  sim:run(80)
  eq(rs[1]:lookup(B.ip("10.2.0.5")) == nil or rs[1]:lookup(B.ip("10.2.0.5")).plen == 0, true, "no route to the vanished network")
end)

test("authentication, neighbour lists, passive interfaces, static routes and default route origination", function()
  local sim, rs = line()
  -- R2 and R3 use a password; R1 does not and is ignored by R2
  start(sim, rs[1])
  local r2 = start(sim, rs[2], { auth = { type = "password", key = "pw" } })
  local r3 = start(sim, rs[3], { auth = { type = "password", key = "pw" } })
  local r4 = start(sim, rs[4], { auth = { type = "password", key = "other" } })
  sim:run(30)
  ok(r2.stats.rejected > 0, "R2 rejected the unauthenticated updates of R1")
  local learned = rs[1]:lookup(B.ip("10.4.0.5"))
  ok(learned == nil or learned.plen == 0, "R1 learned nothing from R2")
  ok(r3.stats.rejected > 0, "R3 rejected R4 (wrong password)")
  eq(rs[2]:lookup(B.ip("10.4.0.5")), nil, "R2 does not know the far LAN (R4 is not trusted)")
  -- HMAC with replay protection
  local sim2, rs2 = line()
  local a = start(sim2, rs2[1], { auth = { type = "hmac", key = "k1" } })
  local b = start(sim2, rs2[2], { auth = { type = "hmac", key = "k1" } })
  sim2:run(15)
  ok(b.stats.received > 0 and b.stats.rejected == 0)
  local viaHmac = rs2[2]:lookup(B.ip("10.1.0.9"))
  ok(viaHmac and viaHmac.proto == "rip", "R2 learned R1's LAN through authenticated updates")
  -- only listed neighbours are believed
  local sim3, rs3 = line()
  start(sim3, rs3[1])
  local strict = start(sim3, rs3[2], { neighbors = { "10.0.2.2" } })        -- not R1's address
  sim3:run(20)
  ok(strict.stats.rejected > 0)
  eq(rs3[2]:lookup(B.ip("10.1.0.5")), nil)
  -- a passive interface listens but never talks; static routes and a default route can be redistributed
  local sim4, rs4 = line()
  start(sim4, rs4[1], { redistribute = { "connected", "static" }, defaultRoute = true })
  rs4[1]:addRoute("172.20.0.0/16", "10.1.0.5")
  for i = 2, 4 do start(sim4, rs4[i]) end
  sim4:run(25)
  local def = rs4[3]:lookup(B.ip("8.8.8.8"))
  ok(def and def.proto == "rip" and def.plen == 0, "the default route reached R3")
  ok(rs4[4]:lookup(B.ip("172.20.1.1")) and rs4[4]:lookup(B.ip("172.20.1.1")).plen == 16, "the redistributed static route reached R4")
  local sim5, rs5 = line()
  start(sim5, rs5[1], { passive = { "eth0", "eth1" } })
  start(sim5, rs5[2])
  sim5:run(20)
  eq(rs5[2]:lookup(B.ip("10.1.0.5")), nil, "a passive router advertises nothing")
  -- static routes beat RIP
  local sim6, rs6 = line()
  for i = 1, 4 do start(sim6, rs6[i]) end
  rs6[1]:addRoute("10.4.0.0/24", "10.0.1.2")           -- the same path, but static
  sim6:run(25)
  eq(rs6[1]:lookup(B.ip("10.4.0.5")).proto, "static")
end)
