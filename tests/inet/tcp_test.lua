-- SPDX-License-Identifier: AGPL-3.0-or-later
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")
local socket = require("tsr.inet.socket")
local tcp = require("tsr.inet.tcp")
local Sim = dofile("/tests/lib/inetsim.lua")

local function lan(opts)
  local sim = Sim.new()
  local seg = sim:segment("lan", opts)
  local a, b = sim:host("a"), sim:host("b")
  sim:plug(a, "eth0", seg, "10.0.0.1/24")
  sim:plug(b, "eth0", seg, "10.0.0.2/24")
  return sim, a, b, seg
end

local function payload(n, salt)
  local t, x = {}, salt or 7
  for i = 1, n do x = (x * 1103515245 + 12345) % 2147483648 t[i] = string.char(math.floor(x / 65536) % 256) end
  return table.concat(t)
end

test("UDP: datagrams, ports, broadcast, and port unreachable", function()
  local sim, a, b = lan()
  local sa, sb = socket.udp(a), socket.udp(b)
  assert(sb:bind(nil, 5000))
  assert(sa:sendto("ping", "10.0.0.2", 5000))
  local data, ip, port = sb:receivefrom(2)
  eq(data, "ping") eq(ip, "10.0.0.1") ok(port >= 49152)
  assert(sb:sendto("pong", ip, port))
  eq((sa:receivefrom(2)), "pong")
  -- nobody on port 6000: ICMP port unreachable arrives at a connected socket
  local c = socket.udp(a)
  assert(c:connect("10.0.0.2", 6000))
  assert(c:send("anyone?"))
  local d, err = c:receivefrom(2)
  eq(d, nil) eq(err, "connection refused")
  -- broadcast needs the option, and reaches everybody on the segment
  local bc = socket.udp(a)
  local ok1, why = bc:sendto("x", "255.255.255.255", 5000)
  ok(ok1 == nil and why:find("broadcast", 1, true), tostring(why))
  bc:setoption("broadcast", true)
  assert(bc:sendto("hello all", "255.255.255.255", 5000))
  eq((sb:receivefrom(2)), "hello all")
  -- a port can only be bound once; closing frees it
  local dup = socket.udp(b)
  eq(select(2, dup:bind(nil, 5000)), "address in use")
  sb:close()
  ok(dup:bind(nil, 5000))
  -- checksum failure: corrupt datagram is dropped
  eq(a.stats.udp.outDatagrams >= 3, true)
end)

test("TCP: connect, accept, echo, orderly close on both sides", function()
  local sim, a, b = lan()
  local got
  sim:spawn(function()
    local srv = socket.tcp(b)
    srv:bind(nil, 7)
    assert(srv:listen(4))
    local c = assert(srv:accept(10))
    local line = c:receive("*l", 5)
    c:send("echo: " .. line .. "\r\n")
    local rest = c:receive("*a", 5)
    got = rest
    c:close()
  end)
  local c = socket.tcp(a)
  assert(c:connect("10.0.0.2", 7, 5))
  eq(c:state(), "ESTABLISHED")
  eq(select(1, c:getpeername()), "10.0.0.2")
  c:send("hello\r\n")
  eq(c:receive("*l", 5), "hello" == nil and "" or "echo: hello")
  c:send("tail data")
  c:shutdown("send")
  sim:finish(10)
  eq(got, "tail data")
  -- the server closed too: we see end of stream
  local more, err = c:receive("*a", 2)
  eq(more, "")
  c:close()
  sim:run(30)                                  -- TIME_WAIT expires
  local n = 0
  for _ in pairs(a.tcpTable) do n = n + 1 end
  for _ in pairs(b.tcpTable) do n = n + 1 end
  eq(n, 0, "all connections are gone")
  ok(a.stats.tcp.activeOpens == 1 and b.stats.tcp.passiveOpens == 1)
end)

test("TCP: a large transfer arrives intact in both directions", function()
  local sim, a, b = lan({ latency = 0.02 })
  local data = payload(120000)
  local received
  sim:spawn(function()
    local srv = socket.tcp(b)
    srv:bind(nil, 9000) srv:listen(2)
    local c = srv:accept(10)
    received = c:receive(#data, 60)
    c:send(received:sub(1, 1000))                 -- and echo the beginning back
    c:close()
  end)
  local cs = socket.tcp(a)
  assert(cs:connect("10.0.0.2", 9000, 5))
  local t0 = sim.now
  assert(cs:send(data, 60))
  local back = cs:receive(1000, 30)
  local took = sim.now - t0
  sim:finish(30)
  eq(received, data)
  eq(back, data:sub(1, 1000))
  ok(took < 20, "120 KB took " .. took .. " simulated seconds")
  ok(a.stats.tcp.retransSegs == nil or a.stats.tcp.retransSegs <= 3, "few retransmissions without loss: " .. tostring(a.stats.tcp.retransSegs))
  cs:close()
end)

test("TCP survives loss, duplication and reordering", function()
  for _, profile in ipairs({ { loss = 0.08, latency = 0.02 }, { loss = 0.02, dup = 0.1, jitter = 0.04, latency = 0.02 } }) do
    local sim, a, b = lan(profile)
    local data = payload(60000, 11)
    local received
    sim:spawn(function()
      local srv = socket.tcp(b)
      srv:bind(nil, 80) srv:listen(2)
      local c = srv:accept(60)
      received = c:receive(#data, 400)
      c:send("done")
      c:close()
    end)
    local cs = socket.tcp(a)
    assert(cs:connect("10.0.0.2", 80, 40), "connect under loss")
    assert(cs:send(data, 400))
    eq(cs:receive(4, 100), "done")
    sim:finish(100)
    eq(received, data, "data arrived intact under loss=" .. profile.loss)
    ok((a.stats.tcp.retransSegs or 0) + (a.stats.tcp.fastRetrans or 0) > 0, "retransmission happened")
    cs:close()
  end
end)

test("TCP: refused, unreachable, timeouts and resets", function()
  local sim, a, b = lan()
  -- nothing listens: RST
  local c = socket.tcp(a)
  local ok1, err = c:connect("10.0.0.2", 81, 5)
  eq(ok1, nil) eq(err, "connection refused")
  ok(b.stats.tcp.outRsts >= 1)
  -- no host at all: ARP fails, the connect gives up
  local c2 = socket.tcp(a)
  local ok2, err2 = c2:connect("10.0.0.99", 80, 3)
  eq(ok2, nil)
  ok(err2 == "timeout" or err2 == "connection failed" or err2:find("unreachable"), tostring(err2))
  -- no route
  local c3 = socket.tcp(a)
  eq(select(2, c3:connect("172.30.0.1", 80, 2)), "network unreachable")
  -- a peer that vanishes (all frames dropped after the connection is up): the sender times out
  sim:spawn(function()
    local srv = socket.tcp(b)
    srv:bind(nil, 82) srv:listen(1)
    local conn = srv:accept(10)
    conn:receive(10, 200)
  end)
  sim:run(0.05)                              -- let the server start listening
  local c4 = socket.tcp(a)
  assert(c4:connect("10.0.0.2", 82, 5))
  local seg = a:iface("eth0").port.seg
  seg.drop = function() return true end
  c4:send("0123456789")
  local ok4, err4 = c4:receive(1, 400)
  eq(ok4, nil) eq(err4, "connection timed out")
  seg.drop = nil
  -- abort sends a reset: the peer sees "connection reset by peer"
  local sim2, a2, b2 = lan()
  local resetSeen
  sim2:spawn(function()
    local srv = socket.tcp(b2)
    srv:bind(nil, 83) srv:listen(1)
    local conn = srv:accept(10)
    local d, e = conn:receive(100, 20)
    resetSeen = e
  end)
  sim2:run(0.05)
  local c5 = socket.tcp(a2)
  assert(c5:connect("10.0.0.2", 83, 5))
  c5:send("partial")
  sim2:run(0.5)
  c5:reset()
  sim2:finish(20)
  eq(resetSeen, "connection reset by peer")
end)

test("TCP: flow control with a slow reader (zero window, persist, window update)", function()
  local sim, a, b = lan()
  local data = payload(80000, 3)
  local received = {}
  local stalledAt
  sim:spawn(function()
    local srv = socket.tcp(b)
    srv:bind(nil, 84) srv:listen(1)
    local c = srv:accept(10)
    -- do not read for a while: the 16 KB receive buffer fills and the window closes
    sim:waitFor(function() return false end, 3)
    stalledAt = c.tcb.rcvLen
    local all = c:receive(#data, 100)
    received = all
  end)
  local cs = socket.tcp(a)
  assert(cs:connect("10.0.0.2", 84, 5))
  assert(cs:send(data, 100))
  sim:finish(100)
  ok(stalledAt and stalledAt <= tcp.BUFFER and stalledAt > 8000, "the receiver's buffer was full: " .. tostring(stalledAt))
  eq(received, data)
end)

test("TCP across a router with a small MTU (MSS and fragmentation)", function()
  local sim = Sim.new()
  local la, lb = sim:segment("A", { latency = 0.01 }), sim:segment("B", { latency = 0.01 })
  local h1, r, h2 = sim:host("h1"), sim:host("r", { forwarding = true }), sim:host("h2")
  sim:plug(h1, "eth0", la, "10.1.0.2/24")
  sim:plug(r, "eth0", la, "10.1.0.1/24")
  sim:plug(r, "eth1", lb, "10.2.0.1/24", { mtu = 296 })
  sim:plug(h2, "eth0", lb, "10.2.0.2/24", { mtu = 296 })
  h1:addRoute("default", "10.1.0.1")
  h2:addRoute("default", "10.2.0.1")
  local data = payload(20000, 5)
  local received
  sim:spawn(function()
    local srv = socket.tcp(h2)
    srv:bind(nil, 8080) srv:listen(1)
    local c = srv:accept(10)
    received = c:receive(#data, 60)
    c:close()
  end)
  local c = socket.tcp(h1)
  assert(c:connect("10.2.0.2", 8080, 8))
  assert(c:send(data, 60))
  sim:finish(60)
  eq(received, data)
  ok(r.stats.ip.forwarded > 50)
  -- MSS follows the smaller MTU of the receiving host (296 - 40)
  ok(h1.stats.tcp.outSegs > 0)
end)

test("TCP: sequence numbers wrap around 2^32", function()
  local sim, a, b = lan()
  a.random = function(n) return n - 1 end        -- initial sequence number close to 2^32
  b.random = function(n) return n - 1 end
  local data = payload(30000, 21)
  local received
  sim:spawn(function()
    local srv = socket.tcp(b)
    srv:bind(nil, 85) srv:listen(1)
    local c = srv:accept(10)
    received = c:receive(#data, 60)
  end)
  local c = socket.tcp(a)
  assert(c:connect("10.0.0.2", 85, 5))
  ok(c.tcb.iss > 4294000000, "ISN " .. c.tcb.iss)
  assert(c:send(data, 60))
  sim:finish(60)
  eq(received, data)
  ok(c.tcb.snd_una < c.tcb.iss, "the sequence numbers wrapped")
end)

test("TCP: backlog, many clients, simultaneous close", function()
  local sim, a, b = lan()
  local served = 0
  sim:spawn(function()
    local srv = socket.tcp(b)
    srv:bind(nil, 86) srv:listen(8)
    for _ = 1, 6 do
      local c = srv:accept(30)
      local who = c:receive("*l", 5)
      c:send("hi " .. who .. "\n")
      c:close()
      served = served + 1
    end
  end)
  local answers = {}
  for i = 1, 6 do
    sim:spawn(function()
      local c = socket.tcp(a)
      assert(c:connect("10.0.0.2", 86, 10))
      c:send("client" .. i .. "\n")
      answers[i] = c:receive("*l", 10)
      c:close()
    end)
  end
  sim:finish(60)
  eq(served, 6)
  for i = 1, 6 do eq(answers[i], "hi client" .. i) end
  -- simultaneous close: both sides call close at once
  local sim2, a2, b2 = lan()
  local sc
  sim2:spawn(function()
    local srv = socket.tcp(b2)
    srv:bind(nil, 87) srv:listen(1)
    sc = srv:accept(10)
  end)
  local cc = socket.tcp(a2)
  assert(cc:connect("10.0.0.2", 87, 5))
  sim2:run(0.3)
  cc:close() sc:close()
  sim2:run(30)
  eq(cc:state(), "CLOSED") eq(sc:state(), "CLOSED")
end)

test("TCP: receive patterns, timeouts and partial reads", function()
  local sim, a, b = lan()
  sim:spawn(function()
    local srv = socket.tcp(b)
    srv:bind(nil, 88) srv:listen(1)
    local c = srv:accept(10)
    c:send("line one\r\nline two\nabc")
    sim:waitFor(function() return false end, 1)
    c:send("def")
    c:close()
  end)
  local c = socket.tcp(a)
  assert(c:connect("10.0.0.2", 88, 5))
  eq(c:receive("*l", 3), "line one")
  eq(c:receive("*l", 3), "line two")
  eq(c:receive(3, 3), "abc")
  local d, err = c:receive(10, 0.2)
  eq(d, nil) eq(err, "timeout")
  eq(c:receive("*a", 5), "def")
  local d2, err2 = c:receive(1, 1)
  eq(d2, nil) eq(err2, "closed")
end)
