-- SPDX-License-Identifier: AGPL-3.0-or-later
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")
local fwMod = require("tsr.inet.fw")
local ct = require("tsr.inet.fw.conntrack")
local iptables = require("tsr.inet.fw.iptables")
local fwcli = require("tsr.inet.fw.cli")
local socket = require("tsr.inet.socket")
local ICMP = require("tsr.inet.icmp")
local Sim = dofile("/tests/lib/inetsim.lua")

--- LAN (192.168.1.0/24: A, B) -- R -- WAN (203.0.113.0/24: R's outside address .2, ISP router I .1) ; behind I: server S (198.51.100.5) ; X is on the WAN too.
local function world()
  local sim = Sim.new()
  local lan, wan, far = sim:segment("lan"), sim:segment("wan"), sim:segment("far")
  local a, b = sim:host("a"), sim:host("b")
  local r = sim:host("r", { forwarding = true })
  local i = sim:host("i", { forwarding = true })
  local s, x = sim:host("s"), sim:host("x")
  sim:plug(a, "eth0", lan, "192.168.1.10/24") sim:plug(b, "eth0", lan, "192.168.1.11/24")
  sim:plug(r, "eth0", lan, "192.168.1.1/24") sim:plug(r, "eth1", wan, "203.0.113.2/24")
  sim:plug(i, "eth0", wan, "203.0.113.1/24") sim:plug(i, "eth1", far, "198.51.100.1/24")
  sim:plug(x, "eth0", wan, "203.0.113.99/24")
  sim:plug(s, "eth0", far, "198.51.100.5/24")
  a:addRoute("default", "192.168.1.1") b:addRoute("default", "192.168.1.1")
  r:addRoute("default", "203.0.113.1")
  x:addRoute("default", "203.0.113.1")
  s:addRoute("default", "198.51.100.1")            -- S knows only the ISP: private addresses are not routable beyond it
  i:addRoute("203.0.113.0/24", nil, { iface = "eth0" })
  return sim, { a = a, b = b, r = r, i = i, s = s, x = x }
end

local function ipt(fw, line)
  local errs = {}
  local ok = iptables.exec(fw, iptables.tokenize(line), { say = function() end, err = function(t) errs[#errs + 1] = t end })
  assert(ok, line .. ": " .. tostring(errs[1]))
end

local function tcpEchoServer(sim, host, port, tag)
  local daemon = sim:spawn(function()
    local srv = socket.tcp(host)
    srv:bind(nil, port) srv:listen(8)
    while true do
      local c = srv:accept(60)
      if not c then return end
      sim:spawn(function()
        local ip = c:getpeername()
        local line = c:receive("*l", 10)
        if line then c:send((tag or "") .. line .. " from " .. ip .. "\n") end
        c:close()
      end)
    end
  end)
  daemon.daemon = true
end

test("the iptables language: parse, list, save and load round trip, errors", function()
  local sim, h = world()
  local fw = fwMod.install(h.r)
  ipt(fw, "-P FORWARD DROP")
  ipt(fw, "-N LANIN")
  ipt(fw, "-A FORWARD -i eth0 -j LANIN")
  ipt(fw, "-A LANIN -p tcp --dport 80 -j ACCEPT")
  ipt(fw, "-A LANIN -p tcp -m multiport --dports 22,8000:8100 -j ACCEPT")
  ipt(fw, "-A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT")
  ipt(fw, "-I FORWARD 1 -s ! 192.168.1.0/24 -p icmp --icmp-type echo-request -m limit --limit 5/minute -j DROP")
  ipt(fw, "-t nat -A POSTROUTING -o eth1 -j MASQUERADE")
  ipt(fw, "-t nat -A PREROUTING -i eth1 -p tcp --dport 8080 -j DNAT --to-destination 192.168.1.10:80")
  eq(#fw.tables.filter.FORWARD.rules, 3)
  eq(fw.tables.filter.FORWARD.rules[1].src.neg, true)
  eq(fw.tables.filter.LANIN.rules[2].dport.ranges, { { 22, 22 }, { 8000, 8100 } })
  local text = iptables.save(fw)
  ok(text:find("-P FORWARD DROP", 1, true) and text:find("-N LANIN", 1, true) and text:find("-t nat -A POSTROUTING -o eth1 -j MASQUERADE", 1, true), text)
  ok(text:find("--to-destination 203.0.113.2", 1, true) == nil and text:find("--to-destination 192.168.1.10:80", 1, true), text)
  -- load it into a fresh firewall
  local sim2, h2 = world()
  local fw2 = fwMod.install(h2.r)
  eq(iptables.load(fw2, text), {})
  eq(iptables.save(fw2), text)
  -- listing
  local lines = {}
  ok(iptables.exec(fw2, { "-L", "FORWARD", "-n", "-v" }, { say = function(t) lines[#lines + 1] = t end, err = print }))
  ok(lines[1]:find("Chain FORWARD (policy DROP", 1, true) and lines[#lines]:find("state ESTABLISHED,RELATED", 1, true), table.concat(lines, "\n"))
  -- deleting by number and by specification
  ipt(fw2, "-D FORWARD 1")
  ipt(fw2, "-D FORWARD -i eth0 -j LANIN")
  eq(#fw2.tables.filter.FORWARD.rules, 1)
  -- mistakes
  local function bad(line, part)
    local errs = {}
    local ok_ = iptables.exec(fw2, iptables.tokenize(line), { say = function() end, err = function(t) errs[#errs + 1] = t end })
    ok(not ok_ and errs[1]:find(part, 1, true), line .. " -> " .. tostring(errs[1]))
  end
  bad("-A FORWARD -p tcp", "needs a target")
  bad("-A FORWARD -p bogus -j DROP", "unknown protocol")
  bad("-A FORWARD -j MASQUERADE", "nat table")
  bad("-t nat -A PREROUTING -j DNAT", "--to-destination")
  bad("-t nat -A FORWARD -j DROP", "no such chain")
  bad("-A FORWARD -j NOSUCH", "no chain/target")
  bad("-X LANIN", "not empty")
  bad("-P LANIN ACCEPT", "built-in")
  bad("-A FORWARD --dport 99999x -j DROP", "bad destination port")
  bad("-Q", "unknown command")
  bad("-D FORWARD 9", "no rule")
  bad("-t mangle -A FORWARD -j DROP", "no table")
  -- the line parser handles quotes
  eq(iptables.tokenize('-A INPUT -j LOG --log-prefix "ssh attempt: "'), { "-A", "INPUT", "-j", "LOG", "--log-prefix", "ssh attempt: " })
end)

test("masquerading: private hosts reach the outside, replies find their way back, the outside sees only the router", function()
  local sim, h = world()
  local fw = fwMod.install(h.r)
  tcpEchoServer(sim, h.s, 80, "hello ")
  sim:run(0.1)
  -- without NAT the server cannot answer a private address
  local before = socket.tcp(h.a)
  local okBefore = before:connect("198.51.100.5", 80, 3)
  eq(okBefore, nil, "no route back to 192.168.1.10")
  ipt(fw, "-t nat -A POSTROUTING -o eth1 -j MASQUERADE")
  -- both hosts use the same source port: NAT must keep the flows apart
  local results = {}
  for _, who in ipairs({ "a", "b" }) do
    sim:spawn(function()
      local c = socket.tcp(h[who])
      c:bind(nil, 40000)
      assert(c:connect("198.51.100.5", 80, 10))
      c:send("from " .. who .. "\n")
      results[who] = c:receive("*l", 10)
      c:close()
    end)
  end
  sim:finish(30)
  eq(results.a, "hello from a from 203.0.113.2", "the server sees the router's outside address")
  eq(results.b, "hello from b from 203.0.113.2")
  local flows = fw:flows()
  local ports = {}
  for _, f in ipairs(flows) do if f.snat and f.proto == "tcp" and f.orig.dport == 80 then ports[#ports + 1] = f.snat.port end end
  eq(#ports, 2) ok(ports[1] ~= ports[2], "two flows, two outside ports")
  -- UDP and ping through the same NAT
  local u = socket.udp(h.s)
  u:bind(nil, 5300)
  sim:spawn(function()
    local data, ip, port = u:receivefrom(10)
    u:sendto("udp:" .. data .. "@" .. ip, ip, port)
  end)
  local c = socket.udp(h.a)
  c:sendto("hi", "198.51.100.5", 5300)
  local reply = c:receivefrom(5)
  eq(reply, "udp:hi@203.0.113.2")
  local r = ICMP.probe(h.a, "198.51.100.5", { timeout = 3 })
  ok(r.ok, tostring(r.reason))
  eq(r.from, B.ip("198.51.100.5"))
  -- traceroute: the ICMP time-exceeded of the ISP router is translated back for the host behind the NAT
  local t = ICMP.probe(h.a, "198.51.100.5", { ttl = 2, timeout = 3 })
  ok(not t.ok and t.kind == "ttl" and t.from == B.ip("203.0.113.1"), "the error came back through the NAT: " .. tostring(t.reason))
  -- entries expire when the flows end
  sim:run(4000)
  eq(fw.ct.count, 0, "the connection tracking table is empty again")
  eq(fw.ct.stats.expired >= 4, true)
end)

test("port forwarding: the outside reaches a server behind the router, and the server sees the real client", function()
  local sim, h = world()
  local fw = fwMod.install(h.r)
  tcpEchoServer(sim, h.a, 80, "web ")
  sim:run(0.1)
  ipt(fw, "-t nat -A POSTROUTING -o eth1 -j MASQUERADE")
  ipt(fw, "-t nat -A PREROUTING -i eth1 -p tcp --dport 8080 -j DNAT --to-destination 192.168.1.10:80")
  local reply
  sim:spawn(function()
    local c = socket.tcp(h.x)
    assert(c:connect("203.0.113.2", 8080, 10))
    c:send("GET\n")
    reply = c:receive("*l", 10)
    c:close()
  end)
  sim:finish(30)
  eq(reply, "web GET from 203.0.113.99", "the server behind the NAT sees the real address of the client")
  -- other ports of the router are not forwarded
  local c2 = socket.tcp(h.x)
  local okc2, err2 = c2:connect("203.0.113.2", 8081, 3)
  eq(okc2, nil)
  -- the flow shows both translations
  local flows = fw:flows()
  local found
  for _, f in ipairs(flows) do if f.dnat then found = f end end
  ok(found and found.dnat.port == 80 and found.dnat.ip == B.ip("192.168.1.10"))
  -- REDIRECT to a local port
  ipt(fw, "-t nat -A PREROUTING -i eth0 -p tcp --dport 3128 -j REDIRECT --to-ports 80")
  tcpEchoServer(sim, h.r, 80, "proxy ")
  sim:run(0.1)
  local redirected
  sim:spawn(function()
    local c = socket.tcp(h.b)
    assert(c:connect("192.168.1.1", 3128, 10))
    c:send("x\n")
    redirected = c:receive("*l", 10)
  end)
  sim:finish(20)
  eq(redirected, "proxy x from 192.168.1.11")
end)

test("stateful filtering: replies are allowed in, new connections from outside are not", function()
  local sim, h = world()
  local fw = fwMod.install(h.r)
  ipt(fw, "-P INPUT DROP")
  ipt(fw, "-A INPUT -i lo -j ACCEPT")
  ipt(fw, "-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT")
  ipt(fw, "-A INPUT -m state --state INVALID -j DROP")
  ipt(fw, "-A INPUT -p tcp --dport 22 -j ACCEPT")
  tcpEchoServer(sim, h.r, 22, "ssh ")
  tcpEchoServer(sim, h.r, 80, "web ")
  sim:run(0.1)
  -- the outside may open port 22 but not port 80 (silently dropped: the connect just times out)
  local got
  sim:spawn(function()
    local c = socket.tcp(h.x)
    assert(c:connect("203.0.113.2", 22, 5))
    c:send("hi\n")
    got = c:receive("*l", 5)
  end)
  sim:finish(20)
  eq(got, "ssh hi from 203.0.113.99")
  local c80 = socket.tcp(h.x)
  local ok80, err80 = c80:connect("203.0.113.2", 80, 3)
  ok(ok80 == nil and err80 == "timeout", "dropped, not refused: " .. tostring(err80))
  -- the router itself can still ping out: the replies are ESTABLISHED
  ok(ICMP.probe(h.r, "203.0.113.99", { timeout = 3 }).ok, "replies to our own pings are let in")
  -- but pinging the router from outside gets no answer
  ok(not ICMP.probe(h.x, "203.0.113.2", { timeout = 1.5 }).ok)
  -- now allow ping with a rate limit: only a burst gets through
  ipt(fw, "-A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/minute --limit-burst 3 -j ACCEPT")
  local answered = 0
  for _ = 1, 8 do if ICMP.probe(h.x, "203.0.113.2", { timeout = 0.5 }).ok then answered = answered + 1 end end
  eq(answered, 3, "burst of three, then the limit")
  -- an ACK for a connection that does not exist is INVALID and dropped, without a reset
  local hits = fw.tables.filter.INPUT.rules[3].pkts
  local seg = W.tcpEncode(B.ip("203.0.113.99"), B.ip("203.0.113.2"), { sport = 5555, dport = 22, seq = 1000, ack = 2000, flags = W.ACK, window = 100, payload = "" })
  h.x:ipSend({ dst = "203.0.113.2", proto = 6, payload = seg })
  sim:run(0.5)
  eq(fw.tables.filter.INPUT.rules[3].pkts, hits + 1, "counted by the INVALID rule")
  eq(h.r.stats.tcp.outRsts or 0, 0, "and no reset was sent")
  -- counters in the listing
  local lines = {}
  fwcli.iptables({ "-L", "INPUT", "-v", "-n" }, { stack = h.r, fw = fw, say = function(t) lines[#lines + 1] = t end, err = print })
  ok(#lines >= 6 and lines[1]:find("policy DROP", 1, true))
end)

test("REJECT answers politely (reset or ICMP); forward filtering with NAT in the same router", function()
  local sim, h = world()
  local fw = fwMod.install(h.r)
  tcpEchoServer(sim, h.s, 80, "far ")
  sim:run(0.1)
  ipt(fw, "-t nat -A POSTROUTING -o eth1 -j MASQUERADE")
  ipt(fw, "-P FORWARD DROP")
  ipt(fw, "-A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT")
  ipt(fw, "-A FORWARD -i eth0 -o eth1 -p tcp --dport 80 -j ACCEPT")
  ipt(fw, "-A FORWARD -i eth0 -p udp --dport 53 -j REJECT --reject-with icmp-port-unreachable")
  ipt(fw, "-A FORWARD -i eth0 -p tcp --dport 23 -j REJECT")
  local out
  sim:spawn(function()
    local c = socket.tcp(h.a)
    assert(c:connect("198.51.100.5", 80, 10))
    c:send("x\n")
    out = c:receive("*l", 10)
  end)
  sim:finish(20)
  eq(out, "far x from 203.0.113.2")
  -- port 23 is refused with a reset: the client sees it at once, not after a timeout
  local started = sim.now
  local c = socket.tcp(h.a)
  local ok23, err23 = c:connect("198.51.100.5", 23, 5)
  eq(ok23, nil) eq(err23, "connection refused")
  ok(sim.now - started < 1, "the refusal was quick")
  -- UDP to port 53 is rejected with ICMP port unreachable: a connected socket sees it
  local u = socket.udp(h.a)
  u:connect("198.51.100.5", 53)
  u:send("query")
  local data, err = u:receivefrom(2)
  eq(err, "connection refused")
  -- anything else new is dropped silently
  local c25 = socket.tcp(h.a)
  local ok25, err25 = c25:connect("198.51.100.5", 25, 2)
  eq(err25, "timeout")
  -- and the outside cannot start connections to the LAN
  local cx = socket.tcp(h.x)
  ok(cx:connect("192.168.1.10", 80, 2) == nil)
end)

test("connection tracking: states, timeouts, eviction, invalid packets", function()
  local sim, h = world()
  local fw = fwMod.install(h.r)
  tcpEchoServer(sim, h.s, 80, "t ")
  sim:run(0.1)
  ipt(fw, "-t nat -A POSTROUTING -o eth1 -j MASQUERADE")
  local c = socket.tcp(h.a)
  assert(c:connect("198.51.100.5", 80, 5))
  local f = fw:flows()[1]
  eq(f.proto, "tcp") ok(f.state == "ESTABLISHED" or f.state == "SYN_RECV", f.state)
  c:send("x\n") c:receive("*l", 5) c:close()
  sim:run(30)
  local states = {}
  for _, fl in ipairs(fw:flows()) do states[fl.state] = true end
  ok(states.TIME_WAIT or fw.ct.count == 0, "after the close the flow lingers in TIME_WAIT briefly")
  sim:run(60)
  eq(fw.ct.count, 0)
  -- UDP: unreplied flows expire faster than replied ones
  local udp = socket.udp(h.a)
  udp:sendto("x", "198.51.100.5", 9999)
  sim:run(1)
  local udpFlow = fw:flows()[1]
  eq(udpFlow.proto, "udp") eq(udpFlow.state, "UNREPLIED")
  ok(udpFlow.expires <= ct.TIMEOUTS.udpNew)
  -- eviction when the table is full
  local old = ct.MAX_ENTRIES
  ct.MAX_ENTRIES = 5
  for p = 1, 12 do socket.udp(h.a):sendto("y", "198.51.100.5", 20000 + p) end
  sim:run(1)
  ok(fw.ct.count <= 5, "at most 5 entries: " .. fw.ct.count)
  ok(fw.ct.stats.evicted >= 1)
  ct.MAX_ENTRIES = old
  -- tuple extraction and rewriting keep checksums valid
  local seg = W.tcpEncode(B.ip("1.1.1.1"), B.ip("2.2.2.2"), { sport = 1000, dport = 80, seq = 5, ack = 0, flags = W.SYN, window = 100, payload = "" })
  local pkt = { src = B.ip("1.1.1.1"), dst = B.ip("2.2.2.2"), proto = 6, payload = seg, frag = 0 }
  local t = ct.tuple(pkt)
  eq(t.sport, 1000) eq(t.dport, 80)
  ct.rewrite(pkt, { src = B.ip("9.9.9.9"), sport = 4242 })
  ok(pkt.dirty)
  local back = assert(W.tcpDecode(pkt.src, pkt.dst, pkt.payload))
  eq(back.sport, 4242) eq(back.dport, 80) eq(pkt.src, B.ip("9.9.9.9"))
  local up = W.udpEncode(B.ip("1.1.1.1"), B.ip("2.2.2.2"), 53, 53, "dns")
  local upkt = { src = B.ip("1.1.1.1"), dst = B.ip("2.2.2.2"), proto = 17, payload = up, frag = 0 }
  ct.rewrite(upkt, { dst = B.ip("3.3.3.3"), dport = 5353 })
  eq(assert(W.udpDecode(upkt.src, upkt.dst, upkt.payload)).dport, 5353)
  local icmp = W.icmpEncode({ type = 8, rest = B.u16(77) .. B.u16(1), data = "x" })
  local ipkt = { src = B.ip("1.1.1.1"), dst = B.ip("2.2.2.2"), proto = 1, payload = icmp, frag = 0 }
  ct.rewrite(ipkt, { sport = 1234 })
  eq(assert(W.icmpDecode(ipkt.payload)).id, 1234)
end)

test("the commands: iptables, iptables-save, iptables-restore, conntrack", function()
  local sim, h = world()
  local fw = fwMod.install(h.r)
  local lines, errs = {}, {}
  local ctx = { stack = h.r, fw = fw, say = function(t) lines[#lines + 1] = t end, err = function(t) errs[#errs + 1] = t end }
  ok(fwcli.iptables({ "-t", "nat", "-A", "POSTROUTING", "-o", "eth1", "-j", "MASQUERADE" }, ctx), table.concat(errs))
  ok(fwcli.iptables({ "-A", "INPUT", "-p", "tcp", "--dport", "22", "-j", "ACCEPT" }, ctx))
  ok(not fwcli.iptables({ "-A", "INPUT", "-j" }, ctx))
  lines = {}
  ok(fwcli.iptables({ "-S" }, ctx))
  ok(table.concat(lines, "\n"):find("-A INPUT -p tcp --dport 22 -j ACCEPT", 1, true), table.concat(lines, "\n"))
  lines = {}
  ok(fwcli.save({ "-" }, ctx))
  local saved = table.concat(lines, "\n")
  ok(saved:find("-t nat -A POSTROUTING", 1, true))
  require("tsr.vfs").writeFile("/tmp/fw-test.rules", saved)
  ok(fwcli.restore({ "/tmp/fw-test.rules" }, ctx))
  eq(#fw.tables.filter.INPUT.rules, 1)
  ok(not fwcli.restore({ "/tmp/missing.rules" }, ctx))
  lines = {}
  ok(fwcli.conntrack({ "-S" }, ctx))
  ok(lines[1]:find("entries 0", 1, true), lines[1])
  ok(fwcli.conntrack({ "-C" }, ctx) and lines[#lines] == "0")
  ok(not fwcli.conntrack({ "-X" }, ctx))
  require("tsr.vfs").fs.delete("/tmp/fw-test.rules")
end)
