-- SPDX-License-Identifier: AGPL-3.0-or-later
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")
local cli = require("tsr.inet.cli")
local link = require("tsr.inet.link")
local config = require("tsr.inet.config")
local dissect = require("tsr.inet.dissect")
local socket = require("tsr.inet.socket")
local vfs = require("tsr.vfs")
local Sim = dofile("/tests/lib/inetsim.lua")

local function ctxFor(sim, stack)
  local lines, errs = {}, {}
  return { stack = stack, say = function(t) lines[#lines + 1] = t end, err = function(t) errs[#errs + 1] = t end,
    idle = function(s) sim:run(s) end, lines = lines, errs = errs }
end

local function text(ctx) return table.concat(ctx.lines, "\n") end

local function twoNets()
  local sim = Sim.new()
  local la, lb = sim:segment("A"), sim:segment("B")
  local h1, r, h2 = sim:host("h1"), sim:host("r", { forwarding = true }), sim:host("h2")
  sim:plug(h1, "eth0", la, "10.1.0.2/24")
  sim:plug(r, "eth0", la, "10.1.0.1/24")
  sim:plug(r, "eth1", lb, "10.2.0.1/24")
  sim:plug(h2, "eth0", lb, "10.2.0.2/24")
  h1:addRoute("default", "10.1.0.1")
  h2:addRoute("default", "10.2.0.1")
  return sim, h1, r, h2
end

test("ip: addresses, routes, links, neighbours", function()
  local sim, h1, r, h2 = twoNets()
  local c = ctxFor(sim, h1)
  ok(cli.ip({ "addr" }, c))
  ok(text(c):find("inet 10.1.0.2/24 brd 10.1.0.255", 1, true), text(c))
  ok(text(c):find("lo: <UP,LOOPBACK>", 1, true) and text(c):find("link/ether 02:54", 1, true))
  ok(cli.ip({ "addr", "add", "192.168.5.9/24", "dev", "eth0" }, c))
  ok(h1:isLocal(B.ip("192.168.5.9")))
  ok(cli.ip({ "addr", "del", "192.168.5.9/24", "dev", "eth0" }, ctxFor(sim, h1)))
  ok(not h1:isLocal(B.ip("192.168.5.9")))
  local c2 = ctxFor(sim, h1)
  ok(not cli.ip({ "addr", "add", "bogus", "dev", "eth0" }, c2) and #c2.errs == 1)
  local c3 = ctxFor(sim, h1)
  ok(cli.ip({ "route", "add", "10.50.0.0/16", "via", "10.1.0.1", "metric", "7" }, c3), table.concat(c3.errs))
  ok(cli.ip({ "route" }, c3))
  ok(text(c3):find("default via 10.1.0.1 dev eth0 proto static metric 1", 1, true), text(c3))
  ok(text(c3):find("10.50.0.0/16 via 10.1.0.1 dev eth0 proto static metric 7", 1, true), text(c3))
  ok(text(c3):find("10.1.0.0/24 dev eth0 proto connected src 10.1.0.2", 1, true))
  ok(cli.ip({ "route", "del", "10.50.0.0/16" }, c3))
  ok(not cli.ip({ "route", "del", "10.50.0.0/16" }, ctxFor(sim, h1)))
  -- neighbours appear after traffic
  ok(cli.ping({ "10.1.0.1", "-c", "1" }, ctxFor(sim, h1)))
  local c4 = ctxFor(sim, h1)
  cli.ip({ "neigh" }, c4)
  ok(text(c4):find("10.1.0.1 dev eth0 lladdr 02:54", 1, true) and text(c4):find("REACHABLE", 1, true), text(c4))
  ok(cli.ip({ "neigh", "add", "10.1.0.77", "lladdr", "02:00:00:00:00:77", "dev", "eth0" }, c4))
  local c5 = ctxFor(sim, h1)
  cli.ip({ "neigh" }, c5)
  ok(text(c5):find("10.1.0.77 dev eth0 lladdr 02:00:00:00:00:77 PERMANENT", 1, true), text(c5))
  cli.ip({ "neigh", "flush" }, c5)
  eq(h1:neighbour(h1:iface("eth0"), B.ip("10.1.0.1")), nil)
  ok(h1:neighbour(h1:iface("eth0"), B.ip("10.1.0.77")), "static entries survive a flush")
  -- link up/down and vlan creation
  ok(cli.ip({ "link", "set", "eth0", "down" }, ctxFor(sim, h1)))
  ok(not h1:iface("eth0").up)
  ok(cli.ip({ "link", "set", "eth0", "up" }, ctxFor(sim, h1)))
  ok(cli.ip({ "link", "add", "vlan", "link", "eth0", "id", "30" }, ctxFor(sim, h1)))
  ok(h1:iface("eth0.30"))
  local c6 = ctxFor(sim, h1)
  cli.ip({ "-s", "link" }, c6)
  ok(text(c6):find("RX: ", 1, true), text(c6))
  -- forwarding switch
  ok(cli.ip({ "forward", "on" }, ctxFor(sim, h1)) and h1.forwarding)
end)

test("ping and traceroute print what the real tools print", function()
  local sim, h1, r, h2 = twoNets()
  local c = ctxFor(sim, h1)
  ok(cli.ping({ "10.2.0.2", "-c", "3", "-i", "0.2" }, c))
  local t = text(c)
  ok(t:find("PING 10.2.0.2 (10.2.0.2): 32 data bytes", 1, true), t)
  ok(t:find("32 bytes from 10.2.0.2: seq=2 ttl=63 time=", 1, true), t)
  ok(t:find("3 packets transmitted, 3 received, 0% packet loss", 1, true), t)
  ok(t:find("round-trip min/avg/max", 1, true))
  local c2 = ctxFor(sim, h1)
  ok(not cli.ping({ "10.1.0.99", "-c", "1", "-W", "5" }, c2))
  ok(text(c2):find("100% packet loss", 1, true), text(c2))
  local c3 = ctxFor(sim, h1)
  ok(cli.traceroute({ "10.2.0.2", "-q", "1" }, c3))
  local tr = text(c3)
  ok(tr:find(" 1  10.1.0.1", 1, true) and tr:find(" 2  10.2.0.2", 1, true), tr)
  -- a host name that cannot be resolved
  local c4 = ctxFor(sim, h1)
  ok(not cli.ping({ "nowhere.example" }, c4) and c4.errs[1]:find("cannot resolve", 1, true), tostring(c4.errs[1]))
  h1:addHost("fileserver", "10.2.0.2")
  ok(cli.ping({ "fileserver", "-c", "1" }, ctxFor(sim, h1)), "names from the hosts table work")
end)

test("netstat shows listeners and connections, tcpdump captures and filters, nc scans", function()
  local sim, h1, r, h2 = twoNets()
  sim:spawn(function()
    local s = socket.tcp(h2)
    s:bind(nil, 2000) s:listen(2)
    local c = s:accept(20)
    c:receive(5, 20)
    sim:waitFor(function() return false end, 30)
  end)
  sim:run(0.1)
  local cap = ctxFor(sim, h1)
  cap.seconds = 3
  local started
  sim:spawn(function()
    local c = socket.tcp(h1)
    c:connect("10.2.0.2", 2000, 5)
    c:send("hello")
    sim:waitFor(function() return false end, 30)
  end)
  ok(cli.tcpdump({ "-i", "eth0", "tcp", "and", "port", "2000", "-c", "6" }, cap), table.concat(cap.errs))
  local dump = text(cap)
  ok(dump:find("Flags [S], seq", 1, true) and dump:find("10.1.0.2.", 1, true) and dump:find("> 10.2.0.2.2000", 1, true), dump)
  ok(dump:find("Flags [S.]", 1, true), "the SYN-ACK is shown")
  ok(not dump:find("ICMP", 1, true), "the filter hides everything else")
  local ns = ctxFor(sim, h2)
  ok(cli.netstat({ "-l" }, ns))
  ok(text(ns):find("tcp    *:2000", 1, true) and text(ns):find("LISTEN", 1, true), text(ns))
  local ns2 = ctxFor(sim, h2)
  cli.netstat({}, ns2)
  ok(text(ns2):find("ESTABLISHED", 1, true), text(ns2))
  local ns3 = ctxFor(sim, h2)
  cli.netstat({ "-s" }, ns3)
  ok(text(ns3):find("TCP:", 1, true) and text(ns3):find("passiveOpens", 1, true))
  local scan = ctxFor(sim, h1)
  ok(cli.nc({ "-z", "10.2.0.2", "2000" }, scan))
  ok(text(scan):find("succeeded", 1, true))
  local scan2 = ctxFor(sim, h1)
  ok(not cli.nc({ "-z", "10.2.0.2", "2001", "-w", "3" }, scan2))
  ok(scan2.errs[1]:find("refused", 1, true), tostring(scan2.errs[1]))
  -- saved captures can be read back
  local c7 = ctxFor(sim, h1)
  c7.seconds = 2
  sim:spawn(function() require("tsr.inet.icmp").probe(h1, "10.2.0.2", { timeout = 1 }) end)
  ok(cli.tcpdump({ "-w", "/tmp/cap.txt", "icmp" }, c7))
  local c8 = ctxFor(sim, h1)
  ok(cli.tcpdump({ "-r", "/tmp/cap.txt", "icmp" }, c8))
  ok(text(c8):find("ICMP echo request, id", 1, true) and text(c8):find("ICMP echo reply", 1, true), text(c8))
end)

test("capture filters", function()
  local function info(frame) return dissect.parse(frame) end
  local ipPacket = W.ipEncode({ src = B.ip("10.0.0.1"), dst = B.ip("10.0.0.2"), proto = 17, payload = W.udpEncode(B.ip("10.0.0.1"), B.ip("10.0.0.2"), 1234, 53, "x") })
  local frame = W.ethEncode({ dst = B.MAC_BROADCAST, src = B.makeMac(1, 1, 1), type = W.ETH_IPV4, payload = ipPacket })
  local i = info(frame)
  local function matches(...) local f = assert(dissect.filter({ ... })) return f(i) end
  ok(matches("udp") and not matches("tcp") and matches("host", "10.0.0.2") and matches("src", "10.0.0.1") and not matches("dst", "10.0.0.1"))
  ok(matches("port", "53") and not matches("port", "80") and matches("net", "10.0.0.0/24") and not matches("net", "192.168.0.0/16"))
  ok(matches("tcp", "or", "udp") and matches("not", "tcp") and not matches("udp", "and", "port", "80"))
  eq(select(2, dissect.filter({ "bogus" })), "unknown filter word 'bogus'")
  eq(select(2, dissect.filter({ "host", "nope" })), "bad address after host")
  ok(dissect.describe(i):find("UDP, length 1", 1, true) and dissect.describe(i):find("10.0.0.1.1234 > 10.0.0.2.53", 1, true), dissect.describe(i))
end)

-- A fake modem on the simulated air: transmit() puts the raw message on a segment, arrivals go through link.dispatch like modem_message events.
local function fakeModem(sim, seg, name, channels)
  local modem = { channelsOpen = {} }
  local port
  port = sim:port(seg, function(msg) link.dispatch({ "modem_message", name, modem.lastChannel or 7101, 7101, msg, 0 }) end)
  function modem.isWireless() return false end
  function modem.open(ch) modem.channelsOpen[ch] = true modem.lastChannel = ch end
  function modem.close(ch) modem.channelsOpen[ch] = nil end
  function modem.transmit(ch, reply, msg) port.send(msg) end
  return modem
end

test("modem link: frames over fake modems, with and without link encryption", function()
  local sim = Sim.new()
  local air = sim:segment("air")
  local a, b = sim:host("a"), sim:host("b")
  local evil = sim:host("evil")
  local ma, mb, me = fakeModem(sim, air, "mA", 1), fakeModem(sim, air, "mB", 1), fakeModem(sim, air, "mE", 1)
  local ia = assert(link.attachModem(a, { name = "eth0", peripheral = "mA", modem = ma, channel = 7101, key = "secret passphrase" }))
  local ib = assert(link.attachModem(b, { name = "eth0", peripheral = "mB", modem = mb, channel = 7101, key = "secret passphrase" }))
  local ie = assert(link.attachModem(evil, { name = "eth0", peripheral = "mE", modem = me, channel = 7101, key = "wrong passphrase" }))
  a:setAddress("eth0", "10.5.0.1", 24) b:setAddress("eth0", "10.5.0.2", 24) evil:setAddress("eth0", "10.5.0.3", 24)
  ok(ma.channelsOpen[7101], "the channel was opened")
  local ICMP = require("tsr.inet.icmp")
  ok(ICMP.probe(a, "10.5.0.2", { timeout = 3 }).ok, "same key: ping works")
  -- the eavesdropper with the wrong key sees only garbage and cannot talk to the others
  ok(not ICMP.probe(evil, "10.5.0.1", { timeout = 2 }).ok, "wrong key: no connection")
  ok((link.drivers[3].badFrames or 0) > 0, "the wrong-key computer counted bad frames")
  -- a replayed frame is dropped
  local before = b.stats.ip.inReceives
  local captured
  local remove = b:addTap(function(dir, iface, frame) if dir == "rx" then captured = frame end end)
  ICMP.probe(a, "10.5.0.2", { timeout = 2 })
  remove()
  ok(captured)
  local driver = link.drivers[2]
  local replayed = driver.lastRaw
  -- unseal a manually sealed frame with an old counter
  local old = a:iface("eth0").driver
  local n1 = old.txCounter
  old.txCounter = 1
  local sealedOld = nil
  mb.transmit = mb.transmit
  local seenBefore = b.stats.ip.inReceives
  ma.transmit(7101, 7101, "garbage garbage garbage garbage garbage garbage garbage garbage garbage")
  sim:run(0.2)
  eq(b.stats.ip.inReceives, seenBefore, "garbage is ignored")
  old.txCounter = n1
  for i = #link.drivers, 1, -1 do link.detach(link.drivers[i].iface.name) end
end)

test("configuration: snapshot and apply round trip, saved file is valid Lua", function()
  local sim, h1, r, h2 = twoNets()
  r.forwarding = true
  r:addRoute("10.77.0.0/16", "10.1.0.9", { iface = "eth0", metric = 4 })
  r:addHost("web", "10.2.0.2")
  local snap = config.snapshot(r)
  eq(snap.interfaces.eth0.addresses, { "10.1.0.1/24" })
  eq(snap.interfaces.eth1.addresses, { "10.2.0.1/24" })
  eq(snap.forwarding, true)
  eq(snap.hosts.web, "10.2.0.2")
  local path = "/tmp/inet-test-network.lua"
  ok(config.save(snap, path))
  local back = assert(config.load(path))
  eq(back.interfaces.eth1.addresses, { "10.2.0.1/24" })
  eq(back.routes[1][1], "10.77.0.0/16")
  -- apply onto a fresh stack with matching interfaces
  local sim2 = Sim.new()
  local seg = sim2:segment("x")
  local s2 = sim2:host("fresh")
  sim2:plug(s2, "eth0", seg)
  sim2:plug(s2, "eth1", seg)
  local problems = config.apply(s2, back)
  eq(problems, {})
  ok(s2:isLocal(B.ip("10.2.0.1")) and s2.forwarding and s2:resolve("web") == B.ip("10.2.0.2"))
  -- mistakes are reported, not fatal
  local p2 = config.apply(s2, { interfaces = { eth0 = { addresses = { "10.9.9.9/99x" } }, eth9 = {} }, routes = { { "300.0.0.0/8", "1.1.1.1" } } })
  ok(#p2 >= 3, table.concat(p2, " | "))
  vfs.fs.delete(path)
  ok(not config.load("/tmp/missing-network.lua").x)
end)
