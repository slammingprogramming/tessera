-- SPDX-License-Identifier: AGPL-3.0-or-later
local B = require("tsr.inet.bytes")
local udp = require("tsr.ntp.udp")
local ntp = require("tsr.ntp")
local bridge = require("tsr.inet.nodebridge")
local net = require("tsr.net")
local socket = require("tsr.inet.socket")
local Sim = dofile("/tests/lib/inetsim.lua")

local function lan()
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local a, b = sim:host("a"), sim:host("b")
  sim:plug(a, "eth0", seg, "10.0.0.1/24") sim:plug(b, "eth0", seg, "10.0.0.2/24")
  return sim, a, b
end

test("NTP packets: timestamps, header fields, damaged input", function()
  local ms = 1760000000123
  local ts = udp.toNtp(ms)
  eq(#ts, 8)
  ok(math.abs(udp.fromNtp(ts) - ms) < 1, "round trip within a millisecond")
  eq(B.rd32(ts, 1), 1760000000 + udp.EPOCH_OFFSET)
  local pkt = udp.encode({ mode = 4, stratum = 2, refid = "GPS", transmit = ms, origin = ms - 1000, receive = ms - 500 })
  eq(#pkt, 48)
  eq(pkt:byte(1), 0 * 64 + 4 * 8 + 4)
  local d = assert(udp.decode(pkt))
  eq(d.mode, 4) eq(d.version, 4) eq(d.stratum, 2) eq(d.leap, 0)
  ok(math.abs(d.transmit - ms) < 1 and math.abs(d.origin - (ms - 1000)) < 1)
  eq(udp.decode(udp.encode({ mode = 4, stratum = 1, refid = "GPS" })).refid, "GPS")
  eq(udp.decode(udp.encode({ mode = 4, stratum = 2, refid = B.ip("10.0.0.1") })).refid, "10.0.0.1")
  eq(udp.decode(udp.encode({ mode = 4, stratum = 16 })).leap, 3, "unsynchronised servers say so")
  eq(select(2, udp.decode("short")), "short NTP packet")
end)

test("a client measures its clock error against a server over the network", function()
  local sim, a, b = lan()
  local serverOffset = 5000          -- the server clock is 5 seconds ahead of the client clock
  local function realMs() return 1760000000000 + math.floor(sim.now * 1000) end
  local server = udp.server(b, { clock = function() return realMs() + serverOffset end, stratum = function() return 2 end, refid = function() return B.ip("10.0.0.99") end })
  local t = sim:spawn(server.run)
  t.daemon = true
  sim:run(0.1)
  local s = assert(udp.query(a, "10.0.0.2", { clock = realMs }))
  ok(math.abs(s.offset - serverOffset) < 50, "offset " .. s.offset)
  ok(s.delay >= 0 and s.delay < 100, "delay " .. s.delay)
  eq(s.stratum, 2) eq(s.refid, "10.0.0.99")
  -- a quick second query is told to slow down
  local fast, err = udp.query(a, "10.0.0.2", { clock = realMs })
  ok(fast == nil and err:find("slow down", 1, true) and err:find("RATE", 1, true), tostring(err))
  eq(server.limited, 1)
  local best = assert(udp.measure(a, "10.0.0.2", { clock = realMs, samples = 3 }))
  ok(math.abs(best.offset - serverOffset) < 50)
  -- no server: a clear message
  local none = udp.query(a, "10.0.0.99", { clock = realMs, timeout = 1 })
  ok(none == nil)
  local refused, e3 = udp.query(b, "10.0.0.1", { clock = realMs, timeout = 1 })
  ok(refused == nil and e3:find("nothing listens", 1, true), tostring(e3))
  -- an unsynchronised server is not believed
  server.stop = true
  sim:run(2)
  local server2 = udp.server(b, { clock = realMs, stratum = function() return 16 end })
  local t2 = sim:spawn(server2.run) t2.daemon = true
  sim:run(0.1)
  local bad, e4 = udp.query(a, "10.0.0.2", { clock = realMs })
  ok(bad == nil and e4:find("not synchronised", 1, true), tostring(e4))
  -- access list: only listed networks get answers
  server2.stop = true
  sim:run(2)
  local server3 = udp.server(b, { clock = realMs, allow = { "192.168.0.0/16" } })
  local t3 = sim:spawn(server3.run) t3.daemon = true
  sim:run(0.1)
  ok(udp.query(a, "10.0.0.2", { clock = realMs, timeout = 1 }) == nil)
  eq(server3.refused, 1)
end)

test("ntp sync uses a udp source: the clock is corrected through the network", function()
  local sim, a, b = lan()
  local function realMs() return 1760000000000 + math.floor(sim.now * 1000) end
  local server = udp.server(b, { clock = function() return realMs() + 2000 end, stratum = function() return 1 end })
  local t = sim:spawn(server.run) t.daemon = true
  sim:run(0.1)
  socket.setDefault(a)
  local sample, err = ntp.sampleSource({ type = "udp", host = "10.0.0.2" }, { clock = realMs, timeout = 2 })
  socket.setDefault(nil)
  ok(sample, tostring(err))
  ok(math.abs(sample.offset - 2000) < 50)
  eq(sample.stratum, 2, "one step further from the reference than the server")
end)

test("tsr.net over the IP network: discovery by broadcast, direct addressing, pairing and calls", function()
  local sim = Sim.new()
  local la, lb = sim:segment("la"), sim:segment("lb")
  local a, r, b = sim:host("a"), sim:host("r", { forwarding = true }), sim:host("b")
  sim:plug(a, "eth0", la, "10.1.0.2/24") sim:plug(r, "eth0", la, "10.1.0.1/24")
  sim:plug(r, "eth1", lb, "10.2.0.1/24") sim:plug(b, "eth0", lb, "10.2.0.2/24")
  a:addRoute("default", "10.1.0.1") b:addRoute("default", "10.2.0.1")
  local c = sim:host("c")
  sim:plug(c, "eth0", la, "10.1.0.3/24")
  local dir = "/tmp/nodebridge-test"
  if fs.exists(dir) then fs.delete(dir) end
  fs.makeDir(dir)
  local ta = bridge.transport({ stack = a, id = 11, config = { ids = { [22] = "10.2.0.2" } } })
  local tb = bridge.transport({ stack = b, id = 22, config = { ids = { [11] = "10.1.0.2" } } })
  local tc = bridge.transport({ stack = c, id = 33, config = {} })
  local na = net.node({ id = 11, hostname = "alpha", transport = ta, peersPath = dir .. "/a.peers" })
  local nb = net.node({ id = 22, hostname = "beta", transport = tb, peersPath = dir .. "/b.peers" })
  local nc = net.node({ id = 33, hostname = "gamma", transport = tc, peersPath = dir .. "/c.peers" })
  for _, n in ipairs({ na, nb, nc }) do local th = sim:spawn(function() n:run() end) th.daemon = true end
  sim:run(0.2)
  -- addressed by computer id across a router (static mapping)
  local rtt = na:ping(22, 3)
  ok(rtt, "ping across the router")
  ok(nb:ping(11, 3), "and back")
  -- no mapping at all: broadcast discovery works on the same network
  local rtt2 = na:ping(33, 3)
  ok(rtt2, "gamma was found by broadcast on the LAN")
  eq(ta.known[33], B.ip("10.1.0.3"), "and its address was learned")
  ok(ta.stats.broadcasts >= 1)
  -- beta is not on the LAN of c: c cannot reach it without a mapping
  ok(nc:ping(22, 1) == nil)
  -- pairing and an authenticated call over IP
  nb:serve("echo", function(from, method, args) return { got = args } end)
  local pairResult
  sim:spawn(function() nb:pairListen({ code = "ABCDE23456", timeout = 20 }) end)
  sim:run(0.5)
  sim:spawn(function() pairResult = { na:pairConnect(22, "ABCDE23456", 15) } end)
  sim:run(15)
  ok(pairResult and pairResult[1], "paired: " .. tostring(pairResult and pairResult[2]))
  local reply
  sim:spawn(function() reply = { na:call("beta", "echo", "say", { 1, 2, 3 }) } end)
  sim:run(5)
  ok(reply and reply[1], "call: " .. tostring(reply and reply[2]))
  eq(reply[1].got, { 1, 2, 3 })
  fs.delete(dir)
end)
