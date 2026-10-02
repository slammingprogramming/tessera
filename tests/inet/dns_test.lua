-- SPDX-License-Identifier: AGPL-3.0-or-later
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.dns.wire")
local zoneMod = require("tsr.inet.dns.zone")
local serverMod = require("tsr.inet.dns.server")
local client = require("tsr.inet.dns.client")
local dnscli = require("tsr.inet.dns.cli")
local ICMP = require("tsr.inet.icmp")
local vfs = require("tsr.vfs")
local Sim = dofile("/tests/lib/inetsim.lua")

local T = W.TYPES

local ROOT_ZONE = [[
$ORIGIN .
$TTL 1h
@        IN SOA a.root. admin.root. ( 1 3600 600 86400 300 )
@        IN NS  a.root.
a.root.  IN A   10.0.0.1
lan.     IN NS  ns.lan.
ns.lan.  IN A   10.0.0.2
]]

local LAN_ZONE = [[
$ORIGIN lan.
$TTL 1h
@          IN SOA ns.lan. admin.lan. 7 3600 600 86400 300
@          IN NS  ns.lan.
ns         IN A   10.0.0.2
example    IN NS  ns1.example.lan.
ns1.example IN A  10.0.0.3
other      IN NS  ns1.example.lan.
]]

local EXAMPLE_ZONE = [[
$ORIGIN example.lan.
$TTL 300
@        IN SOA ns1 hostmaster (
           2026100201 ; serial
           1h 10m 1d  ; refresh retry expire
           5m )       ; negative ttl
         IN NS  ns1
ns1      IN A   10.0.0.3
www      IN A   10.0.0.30
alias    IN CNAME www
far      IN CNAME target.other.lan.
mail     IN MX  10 smtp
smtp     IN A   10.0.0.25
info     IN TXT "hello world" "second string"
*.wild   IN A   10.0.0.99
big      IN TXT "]] .. string.rep("x", 200) .. [["
big      IN TXT "]] .. string.rep("y", 200) .. [["
big      IN TXT "]] .. string.rep("z", 200) .. [["
]]

local OTHER_ZONE = [[
$ORIGIN other.lan.
$TTL 300
@        IN SOA ns1.example.lan. hostmaster.other.lan. 1 3600 600 86400 300
@        IN NS  ns1.example.lan.
target   IN A   10.0.0.77
]]

local function build()
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local hosts = {}
  for i, name in ipairs({ "root", "tld", "ns1", "resolver", "client", "secondary" }) do
    local h = sim:host(name)
    sim:plug(h, "eth0", seg, "10.0.0." .. i .. "/24")
    hosts[name] = h
  end
  local function server(host, cfg)
    local s = serverMod.new(host, cfg)
    local problems = s:loadZones()
    eq(problems, {})
    for _, job in ipairs(assert(s:workers(2))) do sim:spawn(job) end
    return s
  end
  local servers = {}
  servers.root = server(hosts.root, { zones = { { origin = "", text = ROOT_ZONE } } })
  servers.tld = server(hosts.tld, { zones = { { origin = "lan", text = LAN_ZONE } } })
  servers.ns1 = server(hosts.ns1, { zones = { { origin = "example.lan", text = EXAMPLE_ZONE, allowTransfer = { "10.0.0.6" } }, { origin = "other.lan", text = OTHER_ZONE } } })
  servers.resolver = server(hosts.resolver, { roots = { "10.0.0.1" } })
  hosts.client.dnsServers = { B.ip("10.0.0.4") }
  hosts.client.searchDomains = { "example.lan" }
  client.install(hosts.client)
  sim:run(0.2)
  return sim, hosts, servers
end

test("wire format: round trip with name compression, every record type, truncation", function()
  local m = { id = 4242, qr = true, aa = true, rd = true, ra = true, rcode = 0, questions = { { name = "www.example.lan", type = T.A, class = 1 } },
    answers = {
      { name = "www.example.lan", type = T.CNAME, ttl = 60, data = "host.example.lan" },
      { name = "host.example.lan", type = T.A, ttl = 60, data = B.ip("10.1.2.3") },
      { name = "example.lan", type = T.MX, ttl = 60, data = { preference = 10, exchange = "mail.example.lan" } },
      { name = "example.lan", type = T.TXT, ttl = 60, data = { "v=spf1 -all", "second" } },
      { name = "example.lan", type = T.SOA, ttl = 60, data = { mname = "ns.example.lan", rname = "root.example.lan", serial = 5, refresh = 1, retry = 2, expire = 3, minimum = 4 } },
      { name = "_sip._tcp.example.lan", type = T.SRV, ttl = 60, data = { priority = 1, weight = 2, port = 5060, target = "sip.example.lan" } },
      { name = "3.2.1.10.in-addr.arpa", type = T.PTR, ttl = 60, data = "host.example.lan" },
    } }
  local bytes = W.encode(m)
  local d = assert(W.decode(bytes))
  eq(d.id, 4242) ok(d.qr and d.aa and d.rd and d.ra) eq(#d.answers, 7)
  eq(d.answers[2].data, B.ip("10.1.2.3")) eq(d.answers[3].data.exchange, "mail.example.lan") eq(d.answers[4].data, { "v=spf1 -all", "second" })
  eq(d.answers[5].data.serial, 5) eq(d.answers[6].data.port, 5060) eq(d.answers[7].data, "host.example.lan")
  -- compression made it smaller than the sum of the names
  ok(#bytes < 12 + 7 * 50, "message is " .. #bytes .. " bytes")
  -- truncation: leave out records and set TC
  local cut = assert(W.decode(W.encode(m, 120)))
  ok(cut.tc and #cut.answers < 7 and #cut.answers >= 1)
  -- damaged input
  eq(select(2, W.decode("abc")), "short DNS message")
  local loop = bytes:sub(1, 12) .. "\192\12" .. "\0\1\0\1"        -- a name that points at itself
  ok(W.decode(loop) == nil)
  ok(W.decode(bytes:sub(1, 40)) == nil)
  eq(W.reverseName(B.ip("10.0.0.2")), "2.0.0.10.in-addr.arpa")
end)

test("master files: directives, relative names, parentheses, comments, wildcards; serialize reads back", function()
  local z, problems = zoneMod.parse(EXAMPLE_ZONE)
  eq(problems, {})
  eq(z.origin, "example.lan")
  eq(z:serial(), 2026100201)
  eq(z.soa.data.refresh, 3600) eq(z.soa.data.minimum, 300) eq(z.soa.data.mname, "ns1.example.lan")
  eq(z.names["alias.example.lan"][T.CNAME][1].data, "www.example.lan")
  eq(z.names["mail.example.lan"][T.MX][1].data, { preference = 10, exchange = "smtp.example.lan" })
  eq(z.names["info.example.lan"][T.TXT][1].data, { "hello world", "second string" })
  ok(z.names["example.lan"][T.NS], "a line with no owner continues the previous owner (the SOA's name)")
  -- mistakes are reported with line numbers and the rest still loads
  local z2, p2 = zoneMod.parse("$ORIGIN x.lan.\na A 10.0.0.1\nb A nonsense\nc BOGUS 1\n$TTL banana\nd A 10.0.0.4\n")
  eq(#p2, 3)
  ok(p2[1]:find("line 3", 1, true) and p2[2]:find("line 4", 1, true), p2[1])
  eq(z2.names["d.x.lan"][T.A][1].data, B.ip("10.0.0.4"))
  local back = zoneMod.parse(zoneMod.serialize(z))
  eq(back:serial(), z:serial()) eq(back.count, z.count)
  eq(back.names["info.example.lan"][T.TXT][1].data, { "hello world", "second string" })
end)

test("authoritative answers: data, CNAME, NXDOMAIN, no data, wildcards, referrals with glue", function()
  local z = zoneMod.parse(EXAMPLE_ZONE)
  local r = z:lookup("www.example.lan", T.A)
  eq(r.rcode, 0) ok(r.aa) eq(r.answers[1].data, B.ip("10.0.0.30"))
  local c = z:lookup("alias.example.lan", T.A)
  eq(#c.answers, 2) eq(c.answers[1].type, T.CNAME) eq(c.answers[2].data, B.ip("10.0.0.30"))
  local cross = z:lookup("far.example.lan", T.A)
  eq(#cross.answers, 1, "a CNAME out of the zone is returned as it is")
  local nx = z:lookup("nothing.example.lan", T.A)
  eq(nx.rcode, W.RCODE.NXDOMAIN) eq(nx.authority[1].type, T.SOA) eq(nx.authority[1].ttl, 300)
  local nodata = z:lookup("www.example.lan", T.MX)
  eq(nodata.rcode, 0) eq(#nodata.answers, 0) eq(nodata.authority[1].type, T.SOA)
  local wild = z:lookup("anything.wild.example.lan", T.A)
  eq(wild.answers[1].data, B.ip("10.0.0.99")) eq(wild.answers[1].name, "anything.wild.example.lan")
  local mx = z:lookup("mail.example.lan", T.MX)
  eq(mx.additional[1].data, B.ip("10.0.0.25"), "the address of the exchange comes along")
  ok(z:lookup("other.example", T.A).rcode == W.RCODE.REFUSED)
  -- delegation
  local lan = zoneMod.parse(LAN_ZONE)
  local ref = lan:lookup("www.example.lan", T.A)
  ok(ref.referral and not ref.aa and ref.authority[1].type == T.NS and ref.additional[1].data == B.ip("10.0.0.3"), "referral with glue")
  local own = lan:lookup("ns.lan", T.A)
  eq(own.answers[1].data, B.ip("10.0.0.2"))
end)

test("iterative resolution from the root through two delegations, caching, CNAME across zones", function()
  local sim, hosts, servers = build()
  local c = hosts.client
  local r = assert(client.lookup(c, "www.example.lan", "A"))
  eq(r.rcode, 0) eq(r.answers[1].data, B.ip("10.0.0.30"))
  local rec = servers.resolver.recursor
  ok(rec.queries >= 3, "root, TLD, authoritative: " .. rec.queries)
  ok(servers.root.stats.queries >= 1 and servers.tld.stats.queries >= 1 and servers.ns1.stats.queries >= 1)
  -- the second name in the same zone skips the root and the TLD (the delegation is cached)
  local rootBefore, tldBefore = servers.root.stats.queries, servers.tld.stats.queries
  assert(client.lookup(c, "smtp.example.lan", "A"))
  eq(servers.root.stats.queries, rootBefore) eq(servers.tld.stats.queries, tldBefore)
  -- asking the same thing again is answered by the client cache: no packets at all
  local sent = c.stats.udp.outDatagrams
  assert(client.lookup(c, "smtp.example.lan", "A"))
  eq(c.stats.udp.outDatagrams, sent)
  -- a CNAME that leaves the zone is followed through another zone on the same server
  local far = assert(client.lookup(c, "far.example.lan", "A"))
  local ips = {}
  for _, rr in ipairs(far.answers) do if rr.type == T.A then ips[#ips + 1] = rr.data end end
  eq(ips, { B.ip("10.0.0.77") })
  -- NXDOMAIN is cached too
  local nx = assert(client.lookup(c, "ghost.example.lan", "A"))
  eq(nx.rcode, W.RCODE.NXDOMAIN)
  local ns1Before = servers.ns1.stats.queries
  assert(client.lookup(c, "ghost.example.lan", "A"))
  eq(servers.ns1.stats.queries, ns1Before)
  -- a name in a zone nobody serves: the root says NXDOMAIN
  eq(assert(client.lookup(c, "x.nowhere", "A")).rcode, W.RCODE.NXDOMAIN)
end)

test("stack:resolve uses DNS: ping and sockets by name, search domains, reverse names", function()
  local sim, hosts, servers = build()
  local c = hosts.client
  eq(c:resolve("www.example.lan"), B.ip("10.0.0.30"))
  eq(c:resolve("www"), B.ip("10.0.0.30"), "the search domain example.lan is added")
  eq(c:resolve("alias.example.lan"), B.ip("10.0.0.30"), "CNAME chains lead to the address")
  local ip, why = c:resolve("ghost.example.lan")
  ok(ip == nil and why:find("no such name", 1, true), tostring(why))
  eq(c:resolve("10.1.2.3"), B.ip("10.1.2.3"), "dotted quads are not looked up")
  c:addHost("pinned", "10.0.0.5")
  eq(c:resolve("pinned"), B.ip("10.0.0.5"), "the hosts table comes first")
  local r = ICMP.probe(c, "ns1.example.lan", { timeout = 2 })
  ok(r.ok, tostring(r.reason))
end)

test("truncated answers are repeated over TCP; recursion is only for the allowed networks", function()
  local sim, hosts, servers = build()
  local c = hosts.client
  local r = assert(client.lookup(c, "big.example.lan", "TXT"))
  eq(#r.answers, 3, "three TXT records of 200 bytes do not fit in 512 bytes of UDP")
  ok(servers.ns1.stats.truncated >= 1, "the server cut the UDP answer")
  -- the authoritative server refuses to be a resolver
  local direct = assert(client.query(c, "10.0.0.3", "unrelated.example", "A"))
  eq(direct.rcode, W.RCODE.REFUSED)
  -- a resolver restricted to 192.168.0.0/16 refuses this client
  servers.resolver.allowRecursion = { { B.cidr("192.168.0.0/16") } }
  client.flush(c)
  local refused = assert(client.query(c, "10.0.0.4", "www.example.lan", "A"))
  eq(refused.rcode, W.RCODE.REFUSED)
  servers.resolver.allowRecursion = {}
end)

test("forwarding resolver", function()
  local sim, hosts, servers = build()
  local fwdHost = hosts.secondary
  local fwd = serverMod.new(fwdHost, { forwarders = { "10.0.0.4" } })
  for _, job in ipairs(assert(fwd:workers(1))) do sim:spawn(job) end
  sim:run(0.1)
  local c = hosts.client
  local r = assert(client.query(c, "10.0.0.6", "www.example.lan", "A"))
  eq(r.rcode, 0) eq(r.answers[1].data, B.ip("10.0.0.30")) ok(r.ra)
  ok(servers.resolver.stats.queries >= 1, "the forwarder asked the real resolver")
end)

test("zone transfer: a secondary copies the zone, strangers are refused, changes follow the serial", function()
  local sim, hosts, servers = build()
  local sec = serverMod.new(hosts.secondary, { zones = { { origin = "example.lan", type = "secondary", masters = { "10.0.0.3" } } } })
  sec:loadZones()
  ok(sec:pullZone("example.lan"))
  local z = sec.zones["example.lan"].zone
  eq(z:serial(), 2026100201)
  eq(z.names["www.example.lan"][T.A][1].data, B.ip("10.0.0.30"))
  eq(z.names["info.example.lan"][T.TXT][1].data, { "hello world", "second string" })
  eq(z.count, servers.ns1.zones["example.lan"].zone.count)
  -- the secondary answers authoritatively now
  for _, job in ipairs(assert(sec:workers(1))) do sim:spawn(job) end
  sim:run(0.1)
  local r = assert(client.query(hosts.client, "10.0.0.6", "www.example.lan", "A", { rd = false }))
  ok(r.aa and r.answers[1].data == B.ip("10.0.0.30"))
  -- someone who is not on the allow list gets nothing
  local zone, err = serverMod.axfr(hosts.client, "10.0.0.3", "example.lan")
  eq(zone, nil) eq(err, "refused")
  eq(servers.ns1.stats.transfers, 1 + 1 - 1 + 0 == 1 and 1 or 2)
  -- a change on the primary is picked up by the next pull
  servers.ns1.zones["example.lan"].zone:add({ name = "new.example.lan", type = T.A, ttl = 300, data = B.ip("10.0.0.123") })
  servers.ns1.zones["example.lan"].zone:bumpSerial()
  ok(sec:pullZone("example.lan"))
  eq(sec.zones["example.lan"].zone:serial(), 2026100202)
  ok(sec.zones["example.lan"].zone.names["new.example.lan"])
end)

test("nslookup and dnsctl", function()
  local sim, hosts, servers = build()
  local lines, errs = {}, {}
  local ctx = { stack = hosts.client, say = function(t) lines[#lines + 1] = t end, err = function(t) errs[#errs + 1] = t end }
  ok(dnscli.nslookup({ "www.example.lan" }, ctx), table.concat(errs))
  local text = table.concat(lines, "\n")
  ok(text:find("www.example.lan.", 1, true) and text:find("IN A", 1, true) and text:find("10.0.0.30", 1, true), text)
  lines = {}
  ok(dnscli.nslookup({ "example.lan", "MX", "@10.0.0.3" }, ctx) == false, "no MX at the apex")
  lines = {}
  ok(dnscli.nslookup({ "mail.example.lan", "MX" }, ctx))
  ok(table.concat(lines, "\n"):find("10 smtp.example.lan.", 1, true), table.concat(lines, "\n"))
  lines = {}
  ok(not dnscli.nslookup({ "ghost.example.lan" }, ctx))
  ok(table.concat(lines, "\n"):find("NXDOMAIN", 1, true))
  -- dnsctl on the authoritative server: add a record, it is served and written to the zone file
  local path = "/tmp/dns-test.zone"
  vfs.writeFile(path, EXAMPLE_ZONE)
  local sctx = { stack = hosts.ns1, server = servers.ns1, say = function(t) lines[#lines + 1] = t end, err = function(t) errs[#errs + 1] = t end }
  servers.ns1.zones["example.lan"].file = path
  lines = {}
  ok(dnscli.dnsctl({ "add", "example.lan", "printer", "A", "10.0.0.55" }, sctx), table.concat(errs))
  local r = assert(client.query(hosts.client, "10.0.0.3", "printer.example.lan", "A", { rd = false }))
  eq(r.answers[1].data, B.ip("10.0.0.55"))
  ok(vfs.readFile(path):find("printer", 1, true), "the zone file was updated")
  eq(zoneMod.parse(vfs.readFile(path)):serial(), 2026100202, "and the serial was increased")
  ok(dnscli.dnsctl({ "del", "example.lan", "printer" }, sctx))
  eq(assert(client.query(hosts.client, "10.0.0.3", "printer.example.lan", "A", { rd = false })).rcode, W.RCODE.NXDOMAIN)
  lines = {}
  ok(dnscli.dnsctl({ "zones" }, sctx))
  ok(table.concat(lines, "\n"):find("example.lan", 1, true) and table.concat(lines, "\n"):find("other.lan", 1, true))
  ok(not dnscli.dnsctl({ "add", "nowhere.lan", "x", "A", "10.0.0.1" }, sctx))
  vfs.fs.delete(path)
end)
