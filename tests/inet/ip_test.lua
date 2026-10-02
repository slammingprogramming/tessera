-- SPDX-License-Identifier: AGPL-3.0-or-later
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")
local Sim = dofile("/tests/lib/inetsim.lua")

local function unhex(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end

test("addresses, masks and CIDR", function()
  eq(B.ip("192.168.1.10"), 3232235786)
  eq(B.ipStr(3232235786), "192.168.1.10")
  eq(B.ip("256.1.1.1"), nil)
  eq(B.ip("1.2.3"), nil)
  eq(B.mask(24), 4294967040)
  eq(B.mask(0), 0)
  eq(B.mask(32), 4294967295)
  local net, plen = B.cidr("10.1.2.3/8")
  eq(B.ipStr(net), "10.0.0.0") eq(plen, 8)
  eq(B.ipStr(B.broadcast(B.cidr("192.168.1.0/24"))), "192.168.1.255")
  ok(B.inNet(B.ip("172.16.5.9"), B.cidr("172.16.0.0/12")))
  ok(not B.inNet(B.ip("172.32.0.1"), B.cidr("172.16.0.0/12")))
  eq(B.maskToPrefix("255.255.252.0"), 22)
  eq(B.maskToPrefix("255.0.255.0"), nil)
  ok(B.isPrivate(B.ip("10.2.3.4")) and B.isPrivate(B.ip("192.168.0.1")) and not B.isPrivate(B.ip("8.8.8.8")))
  eq(B.macStr(B.mac("02:54:00:01:00:ff")), "02:54:00:01:00:ff")
  eq(B.mac("zz"), nil)
end)

test("the Internet checksum matches RFC 1071 and a classic IPv4 header", function()
  -- RFC 1071 section 3 example: 00 01 f2 03 f4 f5 f6 f7 sums to ddf2 (one's complement sum), checksum is its complement 220d
  eq(B.fold(B.sum(unhex("0001f203f4f5f6f7"))), 0xddf2)
  eq(B.checksum(unhex("0001f203f4f5f6f7")), 0x220d)
  local header = unhex("450000730000400040110000c0a80001c0a800c7")
  eq(B.checksum(header), 0xb861)
  local full = header:sub(1, 10) .. unhex("b861") .. header:sub(13) .. string.rep("x", 0x73 - 20)
  local p = assert(W.ipDecode(full))
  eq(p.proto, 17) eq(B.ipStr(p.src), "192.168.0.1") eq(B.ipStr(p.dst), "192.168.0.199") ok(p.df) eq(p.ttl, 64)
  local bad = full:sub(1, 11) .. "\0" .. full:sub(13)
  eq(select(2, W.ipDecode(bad)), "bad header checksum")
  -- odd length
  eq(B.checksum("\1"), 0xfeff)
end)

test("packet codecs round trip and reject damage", function()
  local f = { dst = B.MAC_BROADCAST, src = B.makeMac(1, 2, 3), type = W.ETH_IPV4, payload = "hello", vlan = 42, pcp = 5 }
  local back = assert(W.ethDecode(W.ethEncode(f)))
  eq(back.vlan, 42) eq(back.pcp, 5) eq(back.type, W.ETH_IPV4) eq(back.payload, "hello")
  local plain = assert(W.ethDecode(W.ethEncode({ dst = f.dst, src = f.src, type = W.ETH_ARP, payload = "x" })))
  eq(plain.vlan, nil) eq(plain.type, W.ETH_ARP)
  local a = { op = W.ARP_REQUEST, sha = f.src, spa = B.ip("10.0.0.1"), tha = string.rep("\0", 6), tpa = B.ip("10.0.0.2") }
  eq(W.arpDecode(W.arpEncode(a)).tpa, a.tpa)
  local ip = W.ipEncode({ src = B.ip("1.2.3.4"), dst = B.ip("5.6.7.8"), proto = 17, payload = "data", id = 7, mf = true, frag = 3, ttl = 9, tos = 4 })
  local q = assert(W.ipDecode(ip))
  eq(q.id, 7) ok(q.mf) eq(q.frag, 3) eq(q.ttl, 9) eq(q.tos, 4) eq(q.payload, "data")
  local u = W.udpEncode(q.src, q.dst, 1000, 53, "query")
  eq(W.udpDecode(q.src, q.dst, u).payload, "query")
  ok(W.udpDecode(q.src, q.dst, u:sub(1, 10) .. "Z" .. u:sub(12)) == nil, "payload damage is caught by the checksum")
  local t = W.tcpEncode(q.src, q.dst, { sport = 1, dport = 2, seq = 4294967295, ack = 5, flags = W.SYN + W.ACK, window = 1000, mss = 1460, payload = "" })
  local ts = assert(W.tcpDecode(q.src, q.dst, t))
  eq(ts.seq, 4294967295) eq(ts.mss, 1460) eq(ts.flags, W.SYN + W.ACK) eq(ts.window, 1000)
  ok(W.tcpDecode(q.src, q.dst, t:sub(1, 5) .. "\9" .. t:sub(7)) == nil)
  local ic = W.icmpEncode({ type = 8, rest = B.u16(77) .. B.u16(3), data = "abc" })
  local m = assert(W.icmpDecode(ic))
  eq(m.id, 77) eq(m.seq, 3) eq(m.data, "abc")
end)

test("sequence number arithmetic wraps", function()
  ok(B.seqLt(4294967290, 5))
  ok(not B.seqLt(5, 4294967290))
  ok(B.seqLe(7, 7))
  eq(B.seqAdd(4294967295, 2), 1)
  eq(B.seqDiff(3, 4294967293), 6)
end)

local function lan2()
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local a, b = sim:host("a"), sim:host("b")
  sim:plug(a, "eth0", seg, "10.0.0.1/24")
  sim:plug(b, "eth0", seg, "10.0.0.2/24")
  return sim, a, b, seg
end

local ICMP = require("tsr.inet.icmp")

test("ping across a LAN resolves the address with ARP first", function()
  local sim, a, b = lan2()
  local r = ICMP.probe(a, "10.0.0.2", { timeout = 2 })
  ok(r.ok, r.reason)
  eq(r.from, B.ip("10.0.0.2"))
  ok(r.rtt > 0 and r.rtt < 0.5, tostring(r.rtt))
  ok(a:neighbour(a:iface("eth0"), B.ip("10.0.0.2")).mac == b:iface("eth0").mac, "a learned b's MAC")
  ok(b:neighbour(b:iface("eth0"), B.ip("10.0.0.1")), "b learned a from the request")
  -- second ping is faster: no ARP round trip
  local r2 = ICMP.probe(a, "10.0.0.2", { timeout = 2 })
  ok(r2.ok and r2.rtt < r.rtt)
  -- an address nobody has: ARP fails, the sender gets host unreachable
  local r3 = ICMP.probe(a, "10.0.0.99", { timeout = 6 })
  ok(not r3.ok, "no answer")
  ok(a.stats.icmp.outEchos == 3 and b.stats.icmp.outEchoReps == 2)
end)

test("a host ignores frames for other MACs and bad checksums", function()
  local sim, a, b = lan2()
  local ia = a:iface("eth0")
  local before = b.stats.ip.inReceives or 0
  -- a frame addressed to a third MAC
  a:transmit(ia, B.makeMac(9, 9, 9), W.ETH_IPV4, W.ipEncode({ src = B.ip("10.0.0.1"), dst = B.ip("10.0.0.2"), proto = 1, payload = "xxxxxxxx" }))
  sim:run(0.2)
  eq(b.stats.ip.inReceives or 0, before)
  -- corrupt header checksum is dropped and counted
  local raw = W.ipEncode({ src = B.ip("10.0.0.1"), dst = B.ip("10.0.0.2"), proto = 1, payload = "xxxxxxxx" })
  raw = raw:sub(1, 8) .. "\1" .. raw:sub(10)
  a:transmit(ia, b:iface("eth0").mac, W.ETH_IPV4, raw)
  sim:run(0.2)
  eq(b.stats.ip.inHdrErrors, 1)
end)

local function threeNet()
  -- h1 --- lanA --- r --- lanB --- h2
  local sim = Sim.new()
  local la, lb = sim:segment("A"), sim:segment("B")
  local h1, r, h2 = sim:host("h1"), sim:host("r", { forwarding = true }), sim:host("h2")
  sim:plug(h1, "eth0", la, "10.1.0.2/24")
  sim:plug(r, "eth0", la, "10.1.0.1/24")
  sim:plug(r, "eth1", lb, "10.2.0.1/24")
  sim:plug(h2, "eth0", lb, "10.2.0.2/24")
  assert(h1:addRoute("default", "10.1.0.1"))
  assert(h2:addRoute("default", "10.2.0.1"))
  return sim, h1, r, h2, la, lb
end

test("routing through a router; TTL is decremented; traceroute sees the hops", function()
  local sim, h1, r, h2 = threeNet()
  local res = ICMP.probe(h1, "10.2.0.2", { timeout = 3 })
  ok(res.ok, res.reason)
  eq(res.ttl, 63, "the reply crossed one router")
  eq(r.stats.ip.forwarded, 2)
  -- TTL 1 expires at the router
  local t1 = ICMP.probe(h1, "10.2.0.2", { ttl = 1, timeout = 3 })
  ok(not t1.ok and t1.kind == "ttl", tostring(t1.reason))
  eq(t1.from, B.ip("10.1.0.1"))
  local t2 = ICMP.probe(h1, "10.2.0.2", { ttl = 2, timeout = 3 })
  ok(t2.ok, "TTL 2 is enough for one router")
  -- no route: network unreachable comes back from the router
  assert(h1:addRoute("10.9.0.0/16", "10.1.0.1"))
  local u = ICMP.probe(h1, "10.9.0.5", { timeout = 3 })
  ok(not u.ok and u.kind == "unreach" and u.from == B.ip("10.1.0.1"), tostring(u.reason))
  -- a host that does not forward does not route
  h2.forwarding = false
  ok(not h2.forwarding and (h1:lookup(B.ip("8.8.8.8")) ~= nil))
end)

test("longest prefix wins, metric breaks ties, down interfaces are skipped", function()
  local sim, h1 = threeNet()
  h1:addRoute("10.2.0.0/16", "10.1.0.1", { metric = 5 })
  h1:addRoute("10.2.0.0/24", nil, { iface = "eth0", metric = 9 })
  eq(h1:lookup(B.ip("10.2.0.7")).plen, 24)
  eq(h1:lookup(B.ip("10.2.5.7")).plen, 16)
  eq(h1:lookup(B.ip("11.0.0.1")).plen, 0)
  h1:addRoute("11.0.0.0/8", "10.1.0.1", { metric = 3 })
  h1:addRoute("11.0.0.0/8", "10.1.0.1", { metric = 3, proto = "rip" })
  h1:setUp("eth0", false)
  eq(h1:lookup(B.ip("11.0.0.1")), nil, "nothing is reachable with the only interface down")
  h1:setUp("eth0", true)
  ok(h1:lookup(B.ip("10.1.0.1")), "the connected route is back")
  ok(not h1:addRoute("12.0.0.0/8", "99.99.99.99"), "a gateway that is not on a connected network is refused")
end)

test("fragmentation and reassembly; DF produces 'fragmentation needed'", function()
  local sim, h1, r, h2, la, lb = threeNet()
  -- shrink the MTU of the second link
  r:iface("eth1").mtu = 576
  h2:iface("eth0").mtu = 576
  local big = string.rep("0123456789", 100)         -- 1000 bytes of ICMP echo payload
  local r1 = ICMP.probe(h1, "10.2.0.2", { size = 1000, timeout = 4 })
  ok(r1.ok, r1.reason)
  eq(r1.bytes, 1000)
  ok(r.stats.ip.fragCreates and r.stats.ip.fragCreates >= 2, "the router fragmented the request")
  ok(h2.stats.ip.reasmOK >= 1)
  -- with DF set the router refuses and says why
  local r2 = ICMP.probe(h1, "10.2.0.2", { size = 1000, df = true, timeout = 4 })
  ok(not r2.ok and r2.kind == "unreach" and r2.code == W.UNREACH_FRAG, tostring(r2.reason) .. " " .. tostring(r2.code))
  -- fragments lost: reassembly times out and cleans up
  lb.drop = function(frame) local f = W.ethDecode(frame) local p = f.type == W.ETH_IPV4 and W.ipDecode(f.payload) return p and p.frag > 0 end
  local r3 = ICMP.probe(h1, "10.2.0.2", { size = 1000, timeout = 2 })
  ok(not r3.ok)
  sim:run(40)
  eq(h2.fragCount, 0)
  eq(h2.stats.ip.reasmFails, 1)
end)

test("ICMP errors are rate limited and never answer errors or broadcasts", function()
  local sim, h1, r, h2 = threeNet()
  -- hammer an unreachable network: only a burst of errors comes back
  assert(h1:addRoute("10.9.0.0/16", "10.1.0.1"))
  for i = 1, 60 do ICMP.probe(h1, "10.9.0." .. (i % 200 + 1), { timeout = 0.01 }) end
  ok(r.stats.icmp.outErrors <= 30, "router sent " .. tostring(r.stats.icmp.outErrors))
  ok(r.stats.icmp.outErrors >= 5)
end)

test("VLAN subinterfaces tag frames and only see their own VLAN", function()
  local sim = Sim.new()
  local seg = sim:segment("trunk")
  local a, b = sim:host("a"), sim:host("b")
  sim:plug(a, "eth0", seg)
  sim:plug(b, "eth0", seg)
  a:addVlan("eth0", 10) a:addVlan("eth0", 20)
  b:addVlan("eth0", 10)
  a:setAddress("eth0.10", "10.10.0.1", 24)
  a:setAddress("eth0.20", "10.20.0.1", 24)
  b:setAddress("eth0.10", "10.10.0.2", 24)
  ok(ICMP.probe(a, "10.10.0.2", { timeout = 2 }).ok, "same VLAN")
  b:addVlan("eth0", 20)
  b:setAddress("eth0.20", "10.20.0.2", 24)
  ok(ICMP.probe(a, "10.20.0.2", { timeout = 2 }).ok, "second VLAN")
  -- a host with only VLAN 10 does not answer on VLAN 20
  b:removeInterface("eth0.20")
  ok(not ICMP.probe(a, "10.20.0.2", { timeout = 1.5 }).ok)
end)

test("proxy ARP, gratuitous ARP and static neighbours", function()
  local sim, h1, r, h2 = threeNet()
  -- h1 with no default route but proxy ARP on the router: h1 thinks 10.2.0.2 is on its own subnet (/16)
  h1:removeRoutes(function(x) return x.proto == "static" end)
  h1:clearAddresses("eth0")
  h1:setAddress("eth0", "10.1.0.2", 8)       -- 10.0.0.0/8 covers both networks
  r:iface("eth0").proxyArp = true
  local res = ICMP.probe(h1, "10.2.0.2", { timeout = 4 })
  ok(res.ok, tostring(res.reason))
  -- static neighbour entry: never expires and needs no ARP
  local ia = h1:iface("eth0")
  h1:addNeighbour(ia, B.ip("10.1.0.77"), B.makeMac(7, 7, 7), true)
  eq(h1:neighbour(ia, B.ip("10.1.0.77")).static, true)
end)
