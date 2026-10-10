-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Robustness: every parser that reads bytes from the network must survive garbage. Valid messages are damaged (bytes changed, cut short, extended) and random bytes are
-- thrown at them; a Lua error from such input would be a way for anybody in radio range to stop a service. Deterministic (fixed seeds).
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")
local Sim = dofile("/tests/lib/inetsim.lua")

local seed = 20261003
local FACTOR = 1      -- raise (and change the seed) for a long hunt for new crashes
local function rnd(n)
  seed = (seed * 1103515245 + 12345) % 2147483648
  local r = math.floor(seed / 65536) % 32768
  if n then return r % n + 1 end
  return r / 32768
end

local function randomBytes(n)
  local t = {}
  for i = 1, n do t[i] = string.char(rnd(256) - 1) end
  return table.concat(t)
end

--- A damaged copy of a valid message.
local function mutate(s)
  local kind = rnd(6)
  if #s == 0 then return randomBytes(rnd(20)) end
  if kind == 1 then return s:sub(1, rnd(#s) - 1)                                  -- cut short
  elseif kind == 2 then return s .. randomBytes(rnd(40))                         -- extended
  elseif kind == 3 then
    local i = rnd(#s)
    return s:sub(1, i - 1) .. string.char(rnd(256) - 1) .. s:sub(i + 1)            -- one byte changed
  elseif kind == 4 then
    local t = { s:byte(1, -1) }
    for _ = 1, rnd(6) do t[rnd(#t)] = rnd(256) - 1 end                           -- several bytes changed
    return string.char(table.unpack(t, 1, math.min(#t, 4000)))
  elseif kind == 5 then
    local i = rnd(#s)
    return s:sub(1, i) .. s:sub(i + rnd(8))                                       -- a piece removed
  end
  return string.rep(string.char(255), rnd(#s))                                    -- all ones
end

--- Run fn on many damaged versions of each sample and on random bytes; collect distinct failures.
local function hammer(name, samples, fn, rounds)
  local failures, seen = {}, {}
  local count = 0
  local function try(input)
    count = count + 1
    if count % 40 == 0 then os.queueEvent("fuzz_yield") os.pullEvent("fuzz_yield") end   -- the computer must not be "too long without yielding"
    local ok, err = pcall(fn, input)
    if not ok then
      local msg = tostring(err):gsub("^[^:]*:%d+: ", "")
      if not seen[msg] then
        seen[msg] = true
        failures[#failures + 1] = ("%s: %s  (input %d bytes: %s)"):format(name, msg, #input, (input:sub(1, 24):gsub("[%c\128-\255]", function(c) return ("\\%d"):format(c:byte()) end)))
      end
    end
  end
  rounds = (rounds or 150) * FACTOR
  for _, s in ipairs(samples) do
    try(s)
    for _ = 1, rounds do try(mutate(s)) end
  end
  for _ = 1, rounds do try(randomBytes(rnd(200) - 1)) end
  return failures
end

local function noFailures(list)
  eq(list, {}, table.concat(list, "\n"))
end

--- Frames of a real conversation (ARP, ping, UDP, TCP) captured on a simulated segment.
local function capture()
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local frames = {}
  seg.drop = function(frame) frames[#frames + 1] = frame return false end
  local a, b = sim:host("a"), sim:host("b")
  sim:plug(a, "eth0", seg, "10.0.0.1/24")
  sim:plug(b, "eth0", seg, "10.0.0.2/24")
  local ICMP = require("tsr.inet.icmp")
  local socket = require("tsr.inet.socket")
  local t = sim:spawn(function()
    local l = socket.tcp(b) l:bind(nil, 80) l:listen(2)
    local c = l:accept(5)
    if c then c:send("hello over tcp") c:close() end
  end)
  t.daemon = true
  sim:spawn(function()
    ICMP.probe(a, "10.0.0.2", { timeout = 2 })
    local u = socket.udp(a) u:sendto("udp payload", "10.0.0.2", 9999)
    local c = socket.tcp(a)
    if c:connect("10.0.0.2", 80, 3) then c:receive("*a", 2) c:close() end
  end)
  sim:run(3)
  return frames
end

test("the IP stack survives damaged and random frames", function()
  local frames = capture()
  ok(#frames > 10, "captured " .. #frames .. " frames")
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local host = sim:host("victim")
  sim:plug(host, "eth0", seg, "10.0.0.2/24")
  local iface = host.ifaces.eth0
  local socket = require("tsr.inet.socket")
  local l = socket.tcp(host) l:bind(nil, 80) l:listen(4)
  local u = socket.udp(host) u:bind(nil, 9999)
  local list = hammer("stack:input", frames, function(frame) host:input(iface, frame) host:tick() end, 25)
  noFailures(list)
  -- and the dissector that tcpdump uses
  noFailures(hammer("dissect", frames, function(frame) require("tsr.inet.dissect").parse(frame) end, 40))
  -- the decoders one by one
  noFailures(hammer("ethDecode", frames, function(s) W.ethDecode(s) end, 40))
  local payloads = {}
  for _, fr in ipairs(frames) do local f = W.ethDecode(fr) if f then payloads[#payloads + 1] = f.payload end end
  noFailures(hammer("arpDecode/ipDecode/icmpDecode", payloads, function(s) W.arpDecode(s) W.ipDecode(s) W.icmpDecode(s) end, 40))
  noFailures(hammer("udp/tcpDecode", payloads, function(s) W.udpDecode(B.ip("10.0.0.1"), B.ip("10.0.0.2"), s) W.tcpDecode(B.ip("10.0.0.1"), B.ip("10.0.0.2"), s) end, 40))
  -- the stack is still alive
  ok(host:isLocal(B.ip("10.0.0.2")))
end)

test("DHCP, DNS, RIP, BGP and Wi-Fi decoders survive garbage", function()
  local dhcpW = require("tsr.dhcp.wire")
  local dnsW = require("tsr.inet.dns.wire")
  local dhcpSamples = { dhcpW.encode({ op = 1, xid = 7, chaddr = string.rep("\1", 6), options = { [53] = "\1", [61] = "\1abcdef" } }) }
  noFailures(hammer("dhcp.decode", dhcpSamples, function(s) dhcpW.decode(s) end, 300))
  local query = dnsW.encode({ id = 5, rd = true, questions = { { name = "www.example.lan", type = 1, class = 1 } }, answers = {}, authority = {}, additional = {} })
  local answer = dnsW.encode({ id = 5, qr = true, aa = true, questions = { { name = "www.example.lan", type = 1, class = 1 } },
    answers = { { name = "www.example.lan", type = 1, class = 1, ttl = 60, data = B.ip("10.0.0.30") }, { name = "x.example.lan", type = 16, class = 1, ttl = 60, data = { "a", "b" } },
      { name = "example.lan", type = 15, class = 1, ttl = 60, data = { preference = 10, exchange = "mail.example.lan" } } }, authority = {}, additional = {} })
  noFailures(hammer("dns.decode", { query, answer }, function(s) dnsW.decode(s) end, 400))
  local rip = require("tsr.inet.route.rip")
  noFailures(hammer("rip.decode", { "\2\2\0\0" .. string.rep("\0\2\0\0\10\0\0\0\255\255\255\0\0\0\0\0\0\0\0\1", 3) }, function(s) rip.decode(s) end, 200))
  local bgpW = require("tsr.inet.bgp.wire")
  local ok1 = pcall(function() return bgpW.parseHeader(string.rep("\255", 16) .. "\0\19\4") end)
  ok(ok1)
  noFailures(hammer("bgp.parse", { string.rep("\255", 16) .. "\0\29\1\4\253\233\0\90\10\0\0\1\0", "\0\0\0\20\64\1\1\0\64\2\4\2\1\253\233\64\3\4\10\0\0\1\24\10\1\2" },
    function(s) bgpW.parseHeader(s) bgpW.parseOpen(s) bgpW.parseUpdate(s) bgpW.parseNotification(s) end, 400))
  local frames = require("tsr.inet.wifi.frames")
  noFailures(hammer("wifi.frames", { "\1\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0" },
    function(s) local f = frames.parse(s) if f then frames.decodeBeacon(f.body or "") frames.decodeEapol(f.body or "") end frames.decodeBeacon(s) frames.decodeEapol(s) frames.decodeProbe(s) frames.decodeAuth(s) frames.decodeAssocReq(s) frames.decodeAssocResp(s) end, 300))
end)

test("HTTP, HTML, mail and message parsers survive garbage", function()
  local msg = require("tsr.inet.http.message")
  noFailures(hammer("http.parse", { "GET /a/b?c=d%20e HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n" },
    function(s) msg.parseHead(s) msg.parseRequestLine(s) msg.parseStatusLine(s) msg.parseUrl(s) msg.parseQuery(s) msg.parseBasicAuth(s) end, 300))
  local html = require("tsr.inet.http.html")
  noFailures(hammer("html.render", { "<html><head><title>x</title></head><body><h1>Hi</h1><p>one <b>two</b> <a href='/x'>link</a></p><ul><li>a<li>b</ul><pre>code</pre></body></html>" },
    function(s) html.render(s, 40) end, 300))
  local mm = require("tsr.mail.message")
  local raw = mm.build({ from = "A <a@x.lan>", to = { "b@y.lan", "c@z.lan" }, subject = "Hi =?UTF-8?B?w6k=?=", body = "text\n.\nmore", host = "x.lan", attachments = { { name = "f.bin", data = "\0\1\2binary", type = "application/octet-stream" } } })
  noFailures(hammer("mail.message", { raw, "Content-Type: multipart/mixed; boundary=zz\r\n\r\n--zz\r\nContent-Type: text/plain\r\n\r\nhi\r\n--zz--\r\n" },
    function(s) local m = mm.parse(s) m:subject() m:from() m:addresses("to") m:text() m:attachments() mm.parseAddressList(s) mm.decodeWords(s) mm.qpDecode(s) end, 300))
  local pasteref = require("tsr.pkg.pasteref")
  noFailures(hammer("pasteref", { "abc+def", "b64:abc+def" }, function(s) pasteref.parse(s) pasteref.fetch(s, function() return "x" end) end, 200))
end)

test("SMTP, POP3, MQTT and Modbus servers survive garbage", function()
  local storeMod = require("tsr.mail.store")
  local mailMod = require("tsr.mail")
  local smtpd = require("tsr.mail.smtpd")
  local pop3d = require("tsr.mail.pop3d")
  local vfs = require("tsr.vfs")
  if vfs.fs.exists("/tmp/fuzz-mail") then vfs.fs.delete("/tmp/fuzz-mail") end
  local sim = Sim.new()
  local h = sim:host("mx")
  local st = storeMod.new({ root = "/tmp/fuzz-mail/mb", users = "/tmp/fuzz-mail/users.db", iterations = 2 })
  st:addUser("alice", "password-alice")
  local m = mailMod.new(h, { hostname = "mx.lan", domains = { "example.lan" }, root = "/tmp/fuzz-mail/mb", users = "/tmp/fuzz-mail/users.db", queueDir = "/tmp/fuzz-mail/q", allowPlainAuth = true }, st)
  local lines = { "EHLO c.lan", "MAIL FROM:<a@b.lan> SIZE=10", "RCPT TO:<alice@example.lan>", "DATA", "AUTH PLAIN AGFsaWNlAHBhc3N3b3JkLWFsaWNl", "AUTH LOGIN", "NOOP", "RSET", "STARTTLS", "VRFY x", "QUIT" }
  noFailures(hammer("smtpd.line", lines, function(line)
    local s = smtpd.session(m, "10.9.9.9", { kind = "submission" })
    s:line("EHLO c") s:line(line)
    s:line("MAIL FROM:<a@b.lan>") s:line("RCPT TO:<alice@example.lan>") s:line("DATA")
    s:dataLine(line) s:dataLine(".")
  end, 200))
  noFailures(hammer("pop3d.line", { "USER alice", "PASS password-alice", "STAT", "LIST 1", "RETR 1", "TOP 1 1", "DELE 1", "UIDL", "CAPA", "QUIT" }, function(line)
    local s = pop3d.session(m, "10.9.9.9")
    s:line("USER alice") s:line("PASS password-alice") s:line(line) s:line("QUIT")
  end, 200))
  -- MQTT: damaged packets into the decoder, and decoded oddities into the broker
  local packet = require("tsr.mqtt.packet")
  local brokerMod = require("tsr.mqtt.broker")
  local samples = {
    packet.encode({ type = "connect", clientId = "c", clean = true, keepalive = 30, username = "u", password = "p", will = { topic = "w", payload = "x", qos = 1 } }),
    packet.encode({ type = "publish", topic = "a/b", payload = "hello", qos = 1, id = 4 }),
    packet.encode({ type = "subscribe", id = 2, topics = { { filter = "a/#", qos = 1 } } }),
    packet.encode({ type = "unsubscribe", id = 3, topics = { "a" } }),
  }
  local broker = brokerMod.new({ allowAnonymous = true, now = function() return 0 end })
  noFailures(hammer("mqtt", samples, function(s)
    local code, flags = math.floor((s:byte(1) or 0) / 16), (s:byte(1) or 0) % 16
    local i = 2
    while (s:byte(i) or 0) >= 128 and i < 6 do i = i + 1 end
    local p = packet.decode(code, flags, s:sub(i + 1))
    local c = broker:open({ send = function() return true end, close = function() end })
    broker:handle(c, { type = "connect", clientId = "f" .. rnd(5), clean = true, keepalive = 10, level = 4 })
    if p then broker:handle(c, p) end
    broker:tick()
  end, 300))
  -- Modbus
  local modbusServer = require("tsr.modbus.server")
  local srv = modbusServer.new({ units = { [1] = { coils = { [0] = { var = "a" }, [1] = { var = "b" } }, inputs = { [0] = { const = true } }, registers = { [0] = { const = 7 } }, holding = { [0] = { var = "h", init = 1 } } } } }, { devices = function() return {} end })
  noFailures(hammer("modbus.request", { "\1\0\0\0\2", "\3\0\0\0\1", "\5\0\0\255\0", "\15\0\0\0\2\1\3", "\16\0\0\0\1\2\0\5", "\6\0\0\0\9" }, function(pdu) srv:request(1, pdu) srv:request(rnd(3), pdu) end, 400))
end)

test("the anti-virus, the learning filter and the SPF/DKIM parsers survive garbage", function()
  local av = require("tsr.av")
  local rules = require("tsr.av.rules")
  noFailures(hammer("av.scanData", { 'local f = fs.open("/startup", "w")\nf.write(http.get("http://x").readAll())\nload(x)()\n-- comment\n[[long]] "str\\"', "\0\1\2binary" },
    function(s) av.scanData(s, { path = "/home/x.lua", defs = { hashes = {}, patterns = {}, allow = {} } }) rules.strip(s) rules.entropy(s) rules.looksLikeLua(s) end, 300))
  local bayes = require("tsr.mail.spam.bayes")
  local b = bayes.new(nil)
  noFailures(hammer("bayes", { "Subject: x\r\n\r\nhello world cheap pills" }, function(s) b:train(s, true) b:classify(s) end, 200))
  local spf = require("tsr.mail.spam.spf")
  local txt = { "v=spf1 a mx ip4:10.0.0.0/24 include:x.lan -all" }
  noFailures(hammer("spf.record", txt, function(record)
    local sim = Sim.new()
    local mail = require("tsr.mail").new(sim:host("m"), { hostname = "m", dnsTxt = function() return { record } end, dnsA = function() return { "10.0.0.5" } end, dnsMx = function() return {} end,
      root = "/tmp/fuzz-mail/mb2", users = "/tmp/fuzz-mail/users2.db" })
    spf.check(mail, "10.0.0.5", "h.lan", "a@x.lan")
  end, 200))
  local dkim = require("tsr.mail.spam.dkim")
  local signed = dkim.sign("From: a@x.lan\r\nSubject: s\r\n\r\nbody\r\n", { domain = "x.lan", selector = "s", seed = string.rep("k", 32), now = 1 })
  noFailures(hammer("dkim.verify", { signed }, function(s)
    local sim = Sim.new()
    local mail = require("tsr.mail").new(sim:host("m2"), { hostname = "m", dnsTxt = function() return { dkim.dnsRecord(string.rep("k", 32)) } end,
      root = "/tmp/fuzz-mail/mb3", users = "/tmp/fuzz-mail/users3.db" })
    dkim.verify(mail, s)
  end, 60))
end)
