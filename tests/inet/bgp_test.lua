-- SPDX-License-Identifier: AGPL-3.0-or-later
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.bgp.wire")
local bgp = require("tsr.inet.bgp")
local bgpcli = require("tsr.inet.bgp.cli")
local ICMP = require("tsr.inet.icmp")
local Sim = dofile("/tests/lib/inetsim.lua")

local TIMERS = { holdTime = 9, keepalive = 3, connectRetry = 3, mrai = 1 }

local function key(net, plen) return net .. "/" .. plen end
local function pfx(text) local n, p = B.cidr(text) return key(n, p) end

--- Build routers for ASes: spec = { A = { as = 65001, lan = "10.1.0.0/16", lanHost = "10.1.0.5" }, ... }, links = { { "A", "B", "192.0.2" }, ... } (a /24 per link, first
--- router gets .1, second .2). Peer configuration is added by the caller before starting.
local function internet(spec, links)
  local sim = Sim.new()
  local world = { sim = sim, r = {}, hosts = {}, segs = {} }
  for name, s in pairs(spec) do
    local r = sim:host("r" .. name, { forwarding = true })
    world.r[name] = r
    local lan = sim:segment("lan" .. name)
    local gw = s.lan:gsub("0/16$", "1")
    sim:plug(r, "lan", lan, gw .. "/16")
    local h = sim:host("h" .. name)
    sim:plug(h, "eth0", lan, s.lanHost .. "/16")
    h:addRoute("default", gw)
    world.hosts[name] = h
  end
  for _, l in ipairs(links) do
    local seg = sim:segment(l[1] .. l[2])
    world.segs[l[1] .. l[2]] = seg
    sim:plug(world.r[l[1]], "to" .. l[2], seg, l[3] .. ".1/24")
    sim:plug(world.r[l[2]], "to" .. l[1], seg, l[3] .. ".2/24")
  end
  return world
end

local function startBgp(world, name, cfg)
  for k, v in pairs(TIMERS) do if cfg[k] == nil then cfg[k] = v end end
  local s = bgp.new(world.r[name], cfg)
  for _, job in ipairs(assert(s:workers())) do local t = world.sim:spawn(job) t.daemon = true end
  world.bgp = world.bgp or {}
  world.bgp[name] = s
  return s
end

local SPEC = {
  A = { as = 65001, lan = "10.1.0.0/16", lanHost = "10.1.0.5" },
  B = { as = 65002, lan = "10.2.0.0/16", lanHost = "10.2.0.5" },
  C = { as = 65003, lan = "10.3.0.0/16", lanHost = "10.3.0.5" },
  D = { as = 65004, lan = "10.4.0.0/16", lanHost = "10.4.0.5" },
  E = { as = 65005, lan = "10.5.0.0/16", lanHost = "10.5.0.5" },
}
local LINKS = { { "A", "B", "192.0.2" }, { "B", "C", "192.0.3" }, { "C", "D", "192.0.4" }, { "B", "E", "192.0.5" }, { "C", "E", "192.0.6" } }

--- A (customer of B), B -- C peers, D (customer of C), E peers with both B and C.
local function standard()
  local w = internet(SPEC, LINKS)
  startBgp(w, "A", { as = 65001, networks = { "10.1.0.0/16" }, peers = { { ip = "192.0.2.2", as = 65002, relationship = "provider" } } })
  startBgp(w, "B", { as = 65002, networks = { "10.2.0.0/16" }, peers = {
    { ip = "192.0.2.1", as = 65001, relationship = "customer" }, { ip = "192.0.3.2", as = 65003, relationship = "peer" }, { ip = "192.0.5.2", as = 65005, relationship = "peer" } } })
  startBgp(w, "C", { as = 65003, networks = { "10.3.0.0/16" }, peers = {
    { ip = "192.0.3.1", as = 65002, relationship = "peer" }, { ip = "192.0.4.2", as = 65004, relationship = "customer" }, { ip = "192.0.6.2", as = 65005, relationship = "peer" } } })
  startBgp(w, "D", { as = 65004, networks = { "10.4.0.0/16" }, peers = { { ip = "192.0.4.1", as = 65003, relationship = "provider" } } })
  startBgp(w, "E", { as = 65005, networks = { "10.5.0.0/16" }, peers = {
    { ip = "192.0.5.1", as = 65002, relationship = "peer" }, { ip = "192.0.6.1", as = 65003, relationship = "peer" } } })
  return w
end

local function best(world, name, prefix) return world.bgp[name].rib[pfx(prefix)] end

test("messages: OPEN, UPDATE with all attributes, KEEPALIVE, NOTIFICATION, prefixes of every length", function()
  local o = W.parseOpen(W.openBody({ as = 65001, holdTime = 90, id = B.ip("1.2.3.4"), auth = "secret-token" }))
  eq(o.version, 4) eq(o.as, 65001) eq(o.holdTime, 90) eq(o.id, B.ip("1.2.3.4")) eq(o.auth, "secret-token")
  local frame = W.frame(W.KEEPALIVE)
  eq(#frame, 19)
  local typ, len = W.parseHeader(frame)
  eq(typ, W.KEEPALIVE) eq(len, 19)
  ok(W.parseHeader("short") == nil)
  ok(W.parseHeader(string.rep("\0", 19)) == nil)
  local nlri = { { net = B.ip("10.0.0.0"), plen = 8 }, { net = B.ip("172.16.4.0"), plen = 22 }, { net = B.ip("192.168.1.128"), plen = 25 }, { net = B.ip("1.2.3.4"), plen = 32 }, { net = 0, plen = 0 } }
  local attrs = { origin = W.ORIGIN_IGP, asPath = { 65001, 65002, 65003 }, nextHop = B.ip("192.0.2.1"), med = 50, localPref = 200, communities = { W.community("65001:100"), W.NO_EXPORT } }
  local body = W.updateBody({ withdrawn = { { net = B.ip("10.9.0.0"), plen = 16 } }, nlri = nlri, attrs = attrs })
  local u = assert(W.parseUpdate(body))
  eq(#u.nlri, 5) eq(u.nlri[2].plen, 22) eq(u.nlri[2].net, B.ip("172.16.4.0")) eq(u.nlri[5].plen, 0)
  eq(u.withdrawn[1].net, B.ip("10.9.0.0"))
  eq(u.attrs.asPath, { 65001, 65002, 65003 }) eq(u.attrs.nextHop, B.ip("192.0.2.1")) eq(u.attrs.med, 50) eq(u.attrs.localPref, 200)
  eq(u.attrs.communities, { 65001 * 65536 + 100, W.NO_EXPORT })
  eq(W.communityText(65001 * 65536 + 100), "65001:100")
  -- a withdraw-only update has no attributes
  local w = assert(W.parseUpdate(W.updateBody({ withdrawn = { { net = B.ip("10.9.0.0"), plen = 16 } } })))
  eq(#w.nlri, 0) eq(#w.withdrawn, 1)
  ok(W.parseUpdate("abc") == nil)
  ok(W.parseUpdate(body:sub(1, 12)) == nil)
  local n = W.parseNotification(W.notification(6, 1, "x"):sub(20))
  eq(n.code, 6) eq(n.sub, 1)
  -- long AS paths use the extended length attribute
  local long = {}
  for i = 1, 150 do long[i] = 60000 + i end
  local lu = assert(W.parseUpdate(W.updateBody({ nlri = { { net = B.ip("10.0.0.0"), plen = 8 } }, attrs = { origin = 0, asPath = long, nextHop = 1, communities = {} } })))
  eq(#lu.attrs.asPath, 150)
end)

test("an internet of five networks: sessions come up, routes spread according to the peering relationships", function()
  local w = standard()
  w.sim:run(40)
  for _, name in ipairs({ "A", "B", "C", "D", "E" }) do ok(w.bgp[name]:established() >= 1, name .. " has a session") end
  eq(w.bgp.B:established(), 3) eq(w.bgp.C:established(), 3)
  -- A (customer of B) learns everything through its provider
  for _, p in ipairs({ "10.2.0.0/16", "10.3.0.0/16", "10.4.0.0/16", "10.5.0.0/16" }) do ok(best(w, "A", p), "A knows " .. p) end
  eq(best(w, "A", "10.4.0.0/16").asPath, { 65002, 65003, 65004 })
  -- D (customer of C) learns everything too
  for _, p in ipairs({ "10.1.0.0/16", "10.2.0.0/16", "10.3.0.0/16", "10.5.0.0/16" }) do ok(best(w, "D", p), "D knows " .. p) end
  -- peers do not carry each other's traffic for free: E peers with B and C but must not be a transit between them
  local viaE = best(w, "C", "10.2.0.0/16")
  eq(viaE.asPath, { 65002 }, "C reaches B directly, not through E")
  local c5 = best(w, "B", "10.5.0.0/16")
  eq(c5.asPath, { 65005 })
  -- B's routes to C's customer D: learned from the peer C: the peer E must not get them from B
  ok(best(w, "E", "10.4.0.0/16").asPath[1] == 65003, "E reaches D through C (its peer), it did not learn it from B")
  ok(best(w, "E", "10.1.0.0/16").asPath[1] == 65002, "and A through B")
  eq(best(w, "E", "10.1.0.0/16").asPath, { 65002, 65001 })
  -- and the peer routes of B are not exported to its peer E:
  ok(w.bgp.E.peers[B.ip("192.0.5.1")].adjIn[pfx("10.3.0.0/16")] == nil, "E does not hear about C from B (peer to peer is not transit)")
  -- real traffic crosses four autonomous systems
  local r = ICMP.probe(w.hosts.A, "10.4.0.5", { timeout = 4 })
  ok(r.ok, tostring(r.reason))
  eq(r.ttl, 64 - 4, "four routers between the LANs of A and D")
  ok(ICMP.probe(w.hosts.D, "10.1.0.5", { timeout = 4 }).ok)
  -- forwarding routes carry the BGP distance
  local route = w.r.A:lookup(B.ip("10.4.0.5"))
  eq(route.proto, "bgp") eq(route.gateway, B.ip("192.0.2.2")) eq(route.metric, bgp.DISTANCE.ebgp + 3)
  -- local preference by relationship: C hears 10.5.0.0/16 from E directly (peer, 100) and from B? (not exported) - only one path
  eq(best(w, "C", "10.5.0.0/16").localPref, 100)
  eq(best(w, "C", "10.4.0.0/16").localPref, 200, "customer routes are preferred")
  eq(best(w, "A", "10.4.0.0/16").localPref, 50, "provider routes are the last resort")
  -- the command
  local lines = {}
  ok(bgpcli.run({ "neighbors" }, { bgp = w.bgp.B, say = function(t) lines[#lines + 1] = t end, err = print }))
  ok(table.concat(lines, "\n"):find("192.0.2.1", 1, true) and table.concat(lines, "\n"):find("Established", 1, true) and table.concat(lines, "\n"):find("customer", 1, true), table.concat(lines, "\n"))
  lines = {}
  ok(bgpcli.run({ "routes", "10.4.0.0/16" }, { bgp = w.bgp.A, say = function(t) lines[#lines + 1] = t end, err = print }))
  ok(lines[1]:find("path 65002 65003 65004", 1, true), lines[1])
  lines = {}
  ok(bgpcli.run({ "status" }, { bgp = w.bgp.C, say = function(t) lines[#lines + 1] = t end, err = print }))
  ok(lines[1]:find("AS65003", 1, true) and lines[1]:find("3 of 3", 1, true), lines[1])
end)

test("a lost session withdraws the routes everywhere, and they come back when the link does", function()
  local w = standard()
  w.sim:run(40)
  ok(best(w, "D", "10.1.0.0/16"))
  -- the cable between A and B stops working
  local seg = w.segs.AB
  seg.drop = function() return true end
  w.sim:run(25)                                  -- hold time is 9 seconds
  eq(w.bgp.B.peers[B.ip("192.0.2.1")].state ~= "Established", true, "B noticed")
  eq(best(w, "B", "10.1.0.0/16"), nil)
  eq(best(w, "D", "10.1.0.0/16"), nil, "the loss reached the far side of the internet")
  eq(w.r.D:lookup(B.ip("10.1.0.5")), nil, "and the forwarding table")
  local reason = w.bgp.B.peers[B.ip("192.0.2.1")].lastError
  ok(tostring(reason):find("hold timer", 1, true) or tostring(reason):find("closed", 1, true), tostring(reason))
  -- the cable is repaired
  seg.drop = nil
  w.sim:run(40)
  ok(best(w, "D", "10.1.0.0/16"), "the route is back")
  ok(ICMP.probe(w.hosts.D, "10.1.0.5", { timeout = 4 }).ok)
end)

test("filters, limits, loop prevention, communities and authentication", function()
  local w = internet({ A = SPEC.A, B = SPEC.B }, { { "A", "B", "192.0.2" } })
  -- A announces its network and two more; B only accepts what its customer is allowed to announce
  w.r.A:addRoute("10.9.0.0/16", nil, { iface = "lan" })
  w.r.A:addRoute("10.8.0.0/16", nil, { iface = "lan" })
  local a = startBgp(w, "A", { as = 65001, networks = { "10.1.0.0/16", "10.9.0.0/16", "10.8.0.0/16" }, peers = { { ip = "192.0.2.2", as = 65002, relationship = "provider" } } })
  local b = startBgp(w, "B", { as = 65002, networks = { "10.2.0.0/16" }, peers = { { ip = "192.0.2.1", as = 65001, relationship = "customer",
    import = { allow = { { prefix = "10.1.0.0/16", le = 24 }, { prefix = "10.9.0.0/16" } }, deny = { { prefix = "10.9.0.0/16" } } } } } })
  w.sim:run(30)
  ok(best(w, "B", "10.1.0.0/16"), "the allowed prefix was accepted")
  eq(best(w, "B", "10.9.0.0/16"), nil, "deny wins over allow")
  eq(best(w, "B", "10.8.0.0/16"), nil, "not on the list")
  local peer = b.peers[B.ip("192.0.2.1")]
  eq(peer.stats.filtered, 2)
  ok(peer.lastRejected:find("import", 1, true), tostring(peer.lastRejected))
  -- a route that already contains our own AS is a loop
  local route, why = b:importRoute(peer, { net = B.ip("10.77.0.0"), plen = 16 }, { asPath = { 65001, 65002, 65009 }, nextHop = B.ip("192.0.2.1"), origin = 0, communities = {} })
  ok(route == nil and why == "AS path loop", tostring(why))
  -- default routes are refused unless asked for
  local def, why2 = b:importRoute(peer, { net = 0, plen = 0 }, { asPath = { 65001 }, nextHop = 1, origin = 0, communities = {} })
  ok(def == nil and why2:find("default route", 1, true))
  -- max-prefix: the session is shut down when the neighbour sends too many
  local w2 = internet({ A = SPEC.A, B = SPEC.B }, { { "A", "B", "192.0.2" } })
  for i = 1, 5 do w2.r.A:addRoute(("10.%d.0.0/16"):format(20 + i), nil, { iface = "lan" }) end
  startBgp(w2, "A", { as = 65001, networks = { "10.20.0.0/16", "10.21.0.0/16", "10.22.0.0/16", "10.23.0.0/16", "10.24.0.0/16" }, peers = { { ip = "192.0.2.2", as = 65002, relationship = "provider" } } })
  local b2 = startBgp(w2, "B", { as = 65002, networks = { "10.2.0.0/16" }, peers = { { ip = "192.0.2.1", as = 65001, relationship = "customer", maxPrefixes = 3 } } })
  w2.sim:run(30)
  local p2 = b2.peers[B.ip("192.0.2.1")]
  ok(p2.state ~= "Established" and tostring(p2.lastError):find("maximum number of prefixes", 1, true), tostring(p2.lastError))
  eq(best(w2, "B", "10.22.0.0/16"), nil, "the routes of a misbehaving neighbour are gone")
  -- a password: the session only comes up when both sides know it
  local w3 = internet({ A = SPEC.A, B = SPEC.B }, { { "A", "B", "192.0.2" } })
  local a3 = startBgp(w3, "A", { as = 65001, networks = { "10.1.0.0/16" }, peers = { { ip = "192.0.2.2", as = 65002, relationship = "provider", password = "tessera" } } })
  local b3 = startBgp(w3, "B", { as = 65002, networks = { "10.2.0.0/16" }, peers = { { ip = "192.0.2.1", as = 65001, relationship = "customer", password = "wrong" } } })
  w3.sim:run(25)
  eq(b3:established(), 0)
  ok(tostring(b3.peers[B.ip("192.0.2.1")].lastError):find("authentication", 1, true) or tostring(a3.peers[B.ip("192.0.2.2")].lastError):find("authentication", 1, true) or tostring(a3.peers[B.ip("192.0.2.2")].lastError):find("notification", 1, true),
    tostring(b3.peers[B.ip("192.0.2.1")].lastError) .. " / " .. tostring(a3.peers[B.ip("192.0.2.2")].lastError))
  b3.peers[B.ip("192.0.2.1")].password = "tessera"
  b3.peers[B.ip("192.0.2.1")].cfg.password = "tessera"
  w3.sim:run(40)
  eq(b3:established(), 1, "with the right password it works")
  -- NO_EXPORT: a community that keeps a route inside our own network
  local noExport = { origin = 0, communities = { W.NO_EXPORT }, asPath = {}, local_ = true, net = B.ip("10.99.0.0"), plen = 16, nextHop = 0, localPref = 1000 }
  local ebgpPeer = b3.peers[B.ip("192.0.2.1")]
  eq(b3:exportAttrs(ebgpPeer, noExport), nil)
  noExport.communities = {}
  ok(b3:exportAttrs(ebgpPeer, noExport))
end)

test("prepending, origin validation (ROA) against a hijack, and administrative reset", function()
  local w = standard()
  w.sim:run(40)
  eq(best(w, "C", "10.1.0.0/16").asPath, { 65002, 65001 })
  -- D (a customer of C) starts announcing A's prefix: without protection C accepts the hijack as a customer route
  w.r.D:addRoute("10.1.0.0/16", nil, { iface = "lan" })
  w.bgp.D.localRoutes[pfx("10.1.0.0/16")] = { net = B.ip("10.1.0.0"), plen = 16, origin = 0, asPath = {}, nextHop = 0, localPref = 1000, communities = {}, local_ = true, routerId = 1 }
  w.bgp.D:recompute(pfx("10.1.0.0/16"))
  w.sim:run(15)
  eq(best(w, "C", "10.1.0.0/16").asPath, { 65004 }, "the hijack won (shorter path and a customer route): traffic for A goes to D")
  -- now C uses ROAs: only AS65001 may originate 10.1.0.0/16 (up to /24)
  local c = w.bgp.C
  c.roas = { { net = B.ip("10.1.0.0"), plen = 16, maxLen = 24, as = 65001 } }
  c.rov = "reject"
  c:clear("192.0.4.2")
  w.sim:run(40)
  local legit = best(w, "C", "10.1.0.0/16")
  eq(legit.asPath, { 65002, 65001 }, "the legitimate origin is used again")
  ok(c.stats.hijacks >= 1, "the invalid announcement was counted")
  eq(c:validate(B.ip("10.1.0.0"), 16, 65001), "valid") eq(c:validate(B.ip("10.1.2.0"), 24, 65001), "valid")
  eq(c:validate(B.ip("10.1.2.0"), 25, 65001), "invalid", "too specific")
  eq(c:validate(B.ip("10.1.0.0"), 16, 65004), "invalid", "wrong origin")
  eq(c:validate(B.ip("172.16.0.0"), 12, 65004), "unknown", "not covered by any ROA")
  -- AS path prepending makes a path less attractive: E announces through C with a long path
  local before = best(w, "B", "10.5.0.0/16")
  eq(before.asPath, { 65005 })
  local pe = w.bgp.E.peers[B.ip("192.0.5.1")]
  pe.prepend = 3
  w.bgp.E.dirty = true
  w.sim:run(10)
  eq(#best(w, "B", "10.5.0.0/16").asPath, 4 - 0 + 0 == 4 and 4 or 4)
  -- an administrative reset reconnects by itself
  ok(w.bgp.B:clear("192.0.3.2"))
  w.sim:run(35)
  eq(w.bgp.B:established(), 3)
end)

test("iBGP: two routers of one network share what they learned, with next-hop-self and recursive next hops", function()
  local sim = Sim.new()
  -- X (AS65001) - B1 (AS65002) == B2 (AS65002) - Y (AS65003); B1 and B2 are connected by an internal link and run iBGP
  local x, b1, b2, y = sim:host("x", { forwarding = true }), sim:host("b1", { forwarding = true }), sim:host("b2", { forwarding = true }), sim:host("y", { forwarding = true })
  local sxb, sbb, sby = sim:segment("xb"), sim:segment("bb"), sim:segment("by")
  sim:plug(x, "e0", sxb, "192.0.2.1/24") sim:plug(b1, "e0", sxb, "192.0.2.2/24")
  sim:plug(b1, "e1", sbb, "10.0.0.1/24") sim:plug(b2, "e0", sbb, "10.0.0.2/24")
  sim:plug(b2, "e1", sby, "192.0.3.1/24") sim:plug(y, "e0", sby, "192.0.3.2/24")
  local lanx, lany = sim:segment("lanx"), sim:segment("lany")
  sim:plug(x, "lan", lanx, "10.1.0.1/16") sim:plug(y, "lan", lany, "10.3.0.1/16")
  local hx, hy = sim:host("hx"), sim:host("hy")
  sim:plug(hx, "eth0", lanx, "10.1.0.5/16") sim:plug(hy, "eth0", lany, "10.3.0.5/16")
  hx:addRoute("default", "10.1.0.1") hy:addRoute("default", "10.3.0.1")
  local function start(host, cfg)
    for k, v in pairs(TIMERS) do cfg[k] = v end
    local s = bgp.new(host, cfg)
    for _, job in ipairs(assert(s:workers())) do local t = sim:spawn(job) t.daemon = true end
    return s
  end
  local sx = start(x, { as = 65001, networks = { "10.1.0.0/16" }, peers = { { ip = "192.0.2.2", as = 65002, relationship = "provider" } } })
  local sb1 = start(b1, { as = 65002, routerId = "10.0.0.1", peers = { { ip = "192.0.2.1", as = 65001, relationship = "customer" }, { ip = "10.0.0.2", as = 65002 } } })
  local sb2 = start(b2, { as = 65002, routerId = "10.0.0.2", peers = { { ip = "10.0.0.1", as = 65002 }, { ip = "192.0.3.2", as = 65003, relationship = "customer" } } })
  local sy = start(y, { as = 65003, networks = { "10.3.0.0/16" }, peers = { { ip = "192.0.3.1", as = 65002, relationship = "provider" } } })
  sim:run(50)
  eq(sb1:established(), 2) eq(sb2:established(), 2)
  local at2 = sb2.rib[pfx("10.1.0.0/16")]
  ok(at2, "B2 learned X's network from B1 over iBGP")
  eq(at2.asPath, { 65001 }, "the AS path is not changed inside the AS")
  eq(at2.nextHop, B.ip("10.0.0.1"), "next-hop-self: B1 is the next hop")
  eq(at2.localPref, 200, "the local preference travelled with it")
  local at_y = sy.rib[pfx("10.1.0.0/16")]
  ok(at_y and at_y.asPath[1] == 65002 and at_y.asPath[2] == 65001, "Y hears it from B2 with the AS path prepended once")
  ok(sx.rib[pfx("10.3.0.0/16")])
  ok(ICMP.probe(hx, "10.3.0.5", { timeout = 5 }).ok, "end to end through the two border routers")
end)
