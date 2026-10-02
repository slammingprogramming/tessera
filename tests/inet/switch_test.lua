-- SPDX-License-Identifier: AGPL-3.0-or-later
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")
local switchMod = require("tsr.inet.switch")
local Stp = require("tsr.inet.switch.stp")
local ICMP = require("tsr.inet.icmp")
local Sim = dofile("/tests/lib/inetsim.lua")

--- A host on its own cable to a switch port. Returns host.
local function attach(sim, sw, portName, hostName, cidr, opts)
  local seg = sim:segment(hostName .. "-" .. portName)
  local h = sim:host(hostName)
  sim:plug(h, "eth0", seg, cidr)
  sim:plug(sw, portName, seg)
  return h, seg
end

local function newSwitch(sim, name, portNames, cfg)
  local sw = sim:host(name, { forwarding = true })
  cfg = cfg or {}
  cfg.name = name
  return sw, cfg
end

local function framesTo(host)
  local n = 0
  local remove = host:addTap(function(dir, iface, frame) if dir == "rx" then n = n + 1 end end)
  return function() return n end, remove
end

test("learning bridge: unicast goes only to the right port after the first exchange", function()
  local sim = Sim.new()
  local sw = sim:host("sw")
  local a = attach(sim, sw, "p1", "a", "10.0.0.1/24")
  local b = attach(sim, sw, "p2", "b", "10.0.0.2/24")
  local c = attach(sim, sw, "p3", "c", "10.0.0.3/24")
  local s = switchMod.new(sw, { ports = { p1 = {}, p2 = {}, p3 = {} }, stp = false })
  s:start()
  local seenByC = framesTo(c)
  ok(ICMP.probe(a, "10.0.0.2", { timeout = 2 }).ok, "ping works through the switch")
  local afterFirst = seenByC()
  ok(afterFirst >= 1, "the ARP broadcast was flooded to c")
  for _ = 1, 5 do ICMP.probe(a, "10.0.0.2", { timeout = 2 }) end
  eq(seenByC(), afterFirst, "later unicast traffic does not reach c")
  local table_ = s:macTable()
  eq(#table_, 2)
  eq(table_[1].port == "p1" or table_[1].port == "p2", true)
  eq(s:lookup(1, a:iface("eth0").mac).port, "p1")
  eq(s:lookup(1, b:iface("eth0").mac).port, "p2")
  -- a host moves to another port: the table follows
  a:iface("eth0").port.down = true
  local seg = sim:segment("moved")
  local ia = a:iface("eth0")
  local port = sim:port(seg, function(frame) a:input(ia, frame) end)
  ia.send = function(frame) port.send(frame) end
  local newPort = sim:port(seg, function(frame) sw:input(sw:iface("p3"), frame) end)
  sw:iface("p3").send = function(frame) newPort.send(frame) end
  c:iface("eth0").port.down = true
  ICMP.probe(a, "10.0.0.2", { timeout = 2 })
  eq(s:lookup(1, a:iface("eth0").mac).port, "p3", "the address was re-learned on the new port")
  eq(s.stats.moves >= 1, true)
  -- entries age out
  sim:run(s.aging + 5)
  eq(s:lookup(1, b:iface("eth0").mac), nil)
end)

test("VLANs: access ports separate networks, a trunk carries tagged frames between switches", function()
  local sim = Sim.new()
  local sw1, sw2 = sim:host("sw1"), sim:host("sw2")
  local a1 = attach(sim, sw1, "p1", "a1", "10.10.0.1/24")
  local b1 = attach(sim, sw1, "p2", "b1", "10.10.0.2/24")
  local c1 = attach(sim, sw1, "p3", "c1", "10.20.0.1/24")
  local a2 = attach(sim, sw2, "p1", "a2", "10.10.0.3/24")
  local c2 = attach(sim, sw2, "p2", "c2", "10.20.0.2/24")
  local trunk = sim:segment("trunk")
  sim:plug(sw1, "t0", trunk)
  sim:plug(sw2, "t0", trunk)
  local frames = {}
  trunk.drop = function(frame) frames[#frames + 1] = frame return false end
  local s1 = switchMod.new(sw1, { ports = { p1 = { vlan = 10 }, p2 = { vlan = 10 }, p3 = { vlan = 20 }, t0 = { mode = "trunk", allowed = { 10, 20 } } }, vlans = { [10] = "sales", [20] = "eng" }, stp = false })
  local s2 = switchMod.new(sw2, { ports = { p1 = { vlan = 10 }, p2 = { vlan = 20 }, t0 = { mode = "trunk", allowed = { 10, 20 } } }, stp = false })
  s1:start() s2:start()
  ok(ICMP.probe(a1, "10.10.0.2", { timeout = 2 }).ok, "same VLAN, same switch")
  local across = ICMP.probe(a1, "10.20.0.1", { timeout = 1 })
  ok(across == nil or not across.ok, "different VLANs do not see each other")
  ok(ICMP.probe(a1, "10.10.0.3", { timeout = 3 }).ok, "VLAN 10 across the trunk")
  ok(ICMP.probe(c1, "10.20.0.2", { timeout = 3 }).ok, "VLAN 20 across the trunk")
  -- frames on the trunk carry the VLAN tag; frames on access cables do not
  local tagged = {}
  for _, fr in ipairs(frames) do local f = W.ethDecode(fr) if f.type == W.ETH_IPV4 or f.type == W.ETH_ARP then tagged[f.vlan or 0] = true end end
  ok(tagged[10] and tagged[20] and not tagged[0], "tags 10 and 20 on the trunk")
  local seenAccess = false
  a1:addTap(function(dir, iface, frame) if dir == "rx" and W.ethDecode(frame).vlan then seenAccess = true end end)
  ICMP.probe(a1, "10.10.0.3", { timeout = 2 })
  ok(not seenAccess, "access ports send untagged frames")
  -- a VLAN that is not allowed on the trunk is cut off
  s1:configurePort("t0", { allowed = { 10 } })
  ok(not ICMP.probe(c1, "10.20.0.2", { timeout = 1 }).ok)
  ok(ICMP.probe(a1, "10.10.0.3", { timeout = 3 }).ok)
  -- a tagged frame on an access port is dropped
  local before = s1.stats.dropped
  local inj = W.ethEncode({ dst = B.MAC_BROADCAST, src = B.makeMac(9, 9, 9), type = W.ETH_ARP, payload = string.rep("\0", 28), vlan = 20 })
  a1:transmit(a1:iface("eth0"), B.MAC_BROADCAST, W.ETH_ARP, string.rep("\0", 28))
  sw1:iface("p1").rxhook(inj)
  ok(s1.stats.dropped > before)
end)

test("an SVI gives the switch an address in a VLAN and routes between VLANs", function()
  local sim = Sim.new()
  local sw = sim:host("sw", { forwarding = true })
  local a = attach(sim, sw, "p1", "a", "10.10.0.5/24")
  local c = attach(sim, sw, "p2", "c", "10.20.0.5/24")
  a:addRoute("default", "10.10.0.1") c:addRoute("default", "10.20.0.1")
  local s = switchMod.new(sw, { ports = { p1 = { vlan = 10 }, p2 = { vlan = 20 } }, stp = false, svis = { [10] = "10.10.0.1/24", [20] = "10.20.0.1/24" } })
  s:start()
  ok(ICMP.probe(a, "10.10.0.1", { timeout = 2 }).ok, "the switch answers on its VLAN 10 address")
  local r = ICMP.probe(a, "10.20.0.5", { timeout = 3 })
  ok(r.ok, tostring(r.reason))
  eq(r.ttl, 63, "routed once, by the switch")
  ok(not a:isLocal(B.ip("10.20.0.1")))
  -- SVI addresses are in the MAC table as belonging to the CPU
  local cpu = 0
  for _, row in ipairs(s:macTable()) do if row.port == "CPU" then cpu = cpu + 1 end end
  eq(cpu, 2)
end)

local function triangle(sim, fd)
  local stp = { forwardDelay = fd or 3, hello = 1, maxAge = 6 }
  local sw = {}
  for i = 1, 3 do sw[i] = sim:host("sw" .. i) end
  local links = {}
  local function link(x, px, y, py)
    local seg = sim:segment("link" .. x .. y)
    sim:plug(sw[x], px, seg)
    sim:plug(sw[y], py, seg)
    links[#links + 1] = seg
    return seg
  end
  link(1, "e12", 2, "e21") link(2, "e23", 3, "e32") link(1, "e13", 3, "e31")
  local h1 = attach(sim, sw[1], "h", "h1", "10.0.0.1/24")
  local h3 = attach(sim, sw[3], "h", "h3", "10.0.0.3/24")
  local s = {}
  s[1] = switchMod.new(sw[1], { ports = { e12 = {}, e13 = {}, h = {} }, stp = { priority = 4096, forwardDelay = stp.forwardDelay, hello = stp.hello, maxAge = stp.maxAge } })
  s[2] = switchMod.new(sw[2], { ports = { e21 = {}, e23 = {} }, stp = { priority = 32768, forwardDelay = stp.forwardDelay, hello = stp.hello, maxAge = stp.maxAge } })
  s[3] = switchMod.new(sw[3], { ports = { e31 = {}, e32 = {}, h = {} }, stp = { priority = 32768, forwardDelay = stp.forwardDelay, hello = stp.hello, maxAge = stp.maxAge } })
  for _, x in ipairs(s) do x:start() end
  return s, links, h1, h3
end

test("spanning tree: a looped triangle settles with one root and one blocked port; traffic does not storm", function()
  local sim = Sim.new()
  local s, links, h1, h3 = triangle(sim)
  sim:run(25)
  ok(s[1].stp:isRoot(), "lowest priority wins the election")
  ok(not s[2].stp:isRoot() and not s[3].stp:isRoot())
  eq(s[2].stp.root, s[1].stp.bridgeId) eq(s[3].stp.root, s[1].stp.bridgeId)
  local blocked, forwarding = 0, 0
  for _, x in ipairs(s) do
    for name, p in pairs(x.ports) do
      if p.stp.state == "blocking" then blocked = blocked + 1 elseif p.stp.state == "forwarding" then forwarding = forwarding + 1 end
    end
  end
  eq(blocked, 1, "exactly one port is blocked in a triangle")
  eq(forwarding, 7, "the other seven ports forward")
  -- the loop does not make broadcast storms: count frames on all links during a few pings
  local before = 0
  for _, l in ipairs(links) do before = before + l.frames end
  for _ = 1, 3 do ok(ICMP.probe(h1, "10.0.0.3", { timeout = 3 }).ok) end
  local after = 0
  for _, l in ipairs(links) do after = after + l.frames end
  ok(after - before < 120, "frames on the inter-switch links: " .. (after - before))
  eq(s[2].stp.rootCost, 19, "switch 2 is one hop from the root")
  ok(s[3].stp.rootCost == 19 or s[3].stp.rootCost == 38)
  -- the blocked port is on a non-root switch, on the link that is not on the shortest path
  -- cable cut: the blocked port takes over
  local cut
  for _, x in ipairs({ s[1], s[2], s[3] }) do
    for name, p in pairs(x.ports) do if p.stp.state == "blocking" then cut = true end end
  end
  ok(cut)
  links[3].drop = function() return true end              -- the cable between sw1 and sw3 fails silently
  sim:run(40)
  local r = ICMP.probe(h1, "10.0.0.3", { timeout = 3 })
  ok(r.ok, "traffic flows over the other path after reconvergence")
  links[3].drop = nil
end)

test("spanning tree: BPDU format, priority vectors, and a bridge that joins late", function()
  local b = { rootId = B.u16(4096) .. B.makeMac(1, 1, 1), cost = 19, bridgeId = B.u16(32768) .. B.makeMac(2, 2, 2), portId = string.char(128, 2), messageAge = 1.5, maxAge = 20, hello = 2, forwardDelay = 15 }
  local payload = Stp.encode(b)
  eq(#payload, 38)
  eq(payload:sub(1, 3), "\66\66\3")
  local d = Stp.decode(payload)
  eq(d.rootId, b.rootId) eq(d.cost, 19) eq(d.bridgeId, b.bridgeId) eq(d.portId, b.portId) eq(d.maxAge, 20) eq(d.hello, 2) eq(d.forwardDelay, 15) eq(d.messageAge, 1.5)
  ok(Stp.better({ root = "a", cost = 5, bridge = "x", port = "1" }, { root = "b", cost = 0, bridge = "a", port = "0" }))
  ok(Stp.better({ root = "a", cost = 4, bridge = "x", port = "1" }, { root = "a", cost = 5, bridge = "a", port = "0" }))
  ok(Stp.better({ root = "a", cost = 4, bridge = "a", port = "1" }, { root = "a", cost = 4, bridge = "b", port = "0" }))
  ok(not Stp.better({ root = "a", cost = 4, bridge = "a", port = "2" }, { root = "a", cost = 4, bridge = "a", port = "1" }))
  eq(Stp.decode("short"), nil)
  -- two switches, one joins later with a better priority and takes over as root
  local sim = Sim.new()
  local sw1, sw2 = sim:host("sw1"), sim:host("sw2")
  local seg = sim:segment("link")
  sim:plug(sw1, "p", seg) sim:plug(sw2, "p", seg)
  local x = switchMod.new(sw1, { ports = { p = {}, q = nil }, stp = { priority = 32768, forwardDelay = 2, hello = 1, maxAge = 6 } })
  sim:plug(sw1, "q", sim:segment("dead1"))
  x:addPort("q", {})
  x.stp = nil
  x = switchMod.new(sw1, { ports = { p = {}, q = {} }, stp = { priority = 32768, forwardDelay = 2, hello = 1, maxAge = 6 } })
  local y = switchMod.new(sw2, { ports = { p = {} }, stp = { priority = 100, forwardDelay = 2, hello = 1, maxAge = 6 } })
  y.stp = require("tsr.inet.switch.stp").new(y, { priority = 100, forwardDelay = 2, hello = 1, maxAge = 6 })
  x:start()
  sim:run(10)
  ok(x.stp:isRoot(), "alone, it is the root")
  y:start()
  sim:run(15)
  ok(not x.stp:isRoot(), "the better bridge became the root")
  eq(x.stp.root, y.stp.bridgeId)
  eq(x.stp.rootPort.name, "p")
end)

test("port security, storm control, mirroring and LLDP", function()
  local sim = Sim.new()
  local sw = sim:host("sw")
  local a = attach(sim, sw, "p1", "a", "10.0.0.1/24")
  local b = attach(sim, sw, "p2", "b", "10.0.0.2/24")
  local mon = attach(sim, sw, "p3", "mon", "10.0.0.9/24")
  -- p1 allows one address; a second computer behind a hub on the same port is a violation
  local s = switchMod.new(sw, { ports = { p1 = { secure = { max = 1, violation = "shutdown" } }, p2 = {}, p3 = {} }, stp = false, mirror = { dest = "p3", sources = { "p1" } } })
  s:start()
  local seenByMon = framesTo(mon)
  ok(ICMP.probe(a, "10.0.0.2", { timeout = 2 }).ok)
  ok(seenByMon() >= 2, "the monitor port sees the traffic of port p1")
  local n = seenByMon()
  ok(ICMP.probe(b, "10.0.0.1", { timeout = 2 }).ok)
  -- an intruder appears on p1's cable
  local seg = a:iface("eth0").port.seg
  local intruder = sim:host("intruder")
  sim:plug(intruder, "eth0", seg, "10.0.0.66/24")
  ICMP.probe(intruder, "10.0.0.2", { timeout = 1 })
  ok(s.ports.p1.errdisabled, "the port shut down after the violation")
  eq(s.ports.p1.counters.violations, 1)
  ok(not ICMP.probe(a, "10.0.0.2", { timeout = 1 }).ok, "even the legitimate computer is cut off until an administrator re-enables the port")
  sim:run(5)                                       -- the intruder gives up retrying
  s:setPortEnabled("p1", true)
  ok(ICMP.probe(a, "10.0.0.2", { timeout = 2 }).ok)
  -- static addresses: only listed MACs may use the port
  s:configurePort("p2", { secure = { static = { B.macStr(b:iface("eth0").mac) }, violation = "protect" } })
  ok(ICMP.probe(b, "10.0.0.1", { timeout = 2 }).ok)
  local rogue = sim:host("rogue")
  sim:plug(rogue, "eth0", b:iface("eth0").port.seg, "10.0.0.77/24")
  ICMP.probe(rogue, "10.0.0.1", { timeout = 1 })
  ok(not s.ports.p2.errdisabled and s.ports.p2.counters.violations >= 1, "protect mode drops silently")
  -- storm control: a flood of broadcasts is limited
  s:configurePort("p3", { storm = 20 })
  local flooded = sim:host("storm")
  local seg3 = mon:iface("eth0").port.seg
  sim:plug(flooded, "eth0", seg3, "10.0.0.50/24")
  local before = s.stats.dropped
  for i = 1, 100 do flooded:transmit(flooded:iface("eth0"), B.MAC_BROADCAST, W.ETH_ARP, string.rep("\0", 28)) end
  sim:run(0.5)
  ok(s.stats.dropped > before + 50, "broadcasts above the limit were dropped: " .. (s.stats.dropped - before))
  -- LLDP: neighbours learn each other's names
  local sim2 = Sim.new()
  local x, y = sim2:host("alpha"), sim2:host("beta")
  local link = sim2:segment("link")
  sim2:plug(x, "p0", link) sim2:plug(y, "p0", link)
  local sx = switchMod.new(x, { name = "alpha", ports = { p0 = {} }, stp = false })
  local sy = switchMod.new(y, { name = "beta", ports = { p0 = {} }, stp = false })
  sx:start() sy:start()
  sim2:run(2)
  local nb = sx:neighbourList()
  eq(#nb, 1) eq(nb[1].name, "beta") eq(nb[1].remotePort, "p0") eq(nb[1].port, "p0")
end)

test("swctl: show, configure ports and VLANs, save and reload the configuration", function()
  local swcli = require("tsr.inet.switch.cli")
  local config = require("tsr.inet.config")
  local vfs = require("tsr.vfs")
  local sim = Sim.new()
  local sw = sim:host("sw", { forwarding = true })
  local a = attach(sim, sw, "p1", "a", "10.10.0.5/24")
  local b = attach(sim, sw, "p2", "b", "10.10.0.6/24")
  local c = attach(sim, sw, "p3", "c", "10.20.0.5/24")
  local s = switchMod.new(sw, { name = "lab", ports = { p1 = {}, p2 = {}, p3 = {} }, stp = false })
  s:start()
  local lines, errs = {}, {}
  local ctx = { switch = s, say = function(t) lines[#lines + 1] = t end, err = function(t) errs[#errs + 1] = t end }
  local function run(...) lines, errs = {}, {} return swcli.run({ ... }, ctx) end
  ok(run("vlan", "add", "10", "sales"), table.concat(errs))
  ok(run("vlan", "add", "20", "eng"))
  ok(run("port", "p1", "access", "10") and run("port", "p2", "access", "10") and run("port", "p3", "access", "20"))
  ok(ICMP.probe(a, "10.10.0.6", { timeout = 2 }).ok)
  local r = ICMP.probe(a, "10.20.0.5", { timeout = 1 })
  ok(r == nil or not r.ok, "VLANs separate the networks")
  ok(run("show", "vlan"))
  ok(table.concat(lines, "\n"):find("10    sales        p1 p2", 1, true), table.concat(lines, "\n"))
  ok(run("show", "mac"))
  ok(table.concat(lines, "\n"):find(B.macStr(a:iface("eth0").mac), 1, true))
  ok(run("show", "ports"))
  ok(table.concat(lines, "\n"):find("p3       access  20", 1, true), table.concat(lines, "\n"))
  ok(run("svi", "10", "10.10.0.1/24"))
  ok(ICMP.probe(a, "10.10.0.1", { timeout = 2 }).ok)
  ok(run("port", "p2", "security", "1", "shutdown") and s.ports.p2.secure.max == 1)
  ok(run("port", "p3", "storm", "50") and s.ports.p3.storm == 50)
  ok(run("mirror", "p3", "p1") and s.mirror.dest == "p3")
  ok(run("mirror", "off") and s.mirror == nil)
  ok(not run("port", "nope", "access", "1"))
  ok(not run("vlan", "del", "10"), "ports still use VLAN 10")
  ok(not run("port", "p1", "bogus"))
  ok(run("show", "neighbors") and run("mac", "flush"))
  eq(#s:macTable(), 1, "after the flush only the SVI address remains")
  -- save and load back
  local path = "/tmp/switch-test.lua"
  local snap = swcli.snapshot(s)
  eq(snap.ports.p1.vlan, 10) eq(snap.ports.p2.secure.violation, "shutdown") eq(snap.svis[10], "10.10.0.1/24") eq(snap.vlans[20], "eng")
  ok(vfs.writeFile(path, "return " .. config.dump(snap)))
  local text = vfs.readFile(path)
  local back = assert(load(text, "=t", "t", {}))()
  eq(back.ports.p3.vlan, 20) eq(back.ports.p3.storm, 50)
  vfs.fs.delete(path)
end)
